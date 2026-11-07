#!/usr/bin/env python3
"""Measure x264 CPU seconds per media second and SSIM on the target host.

Requires ffmpeg and Python 3. Uses private temporary files, never service ports.
Encoding uses two threads; CPU numbers exclude Liquidsoap and input decoding.
Aborts a running FFmpeg if the one-minute system load reaches --max-load.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile
import time


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input', action='append', default=[])
    p.add_argument('--seconds', type=int, default=12)
    p.add_argument('--presets', nargs='+', default=['ultrafast', 'superfast', 'veryfast', 'faster', 'fast'])
    p.add_argument('--threads', type=int, default=2)
    p.add_argument('--max-load', type=float, default=3.5)
    p.add_argument('--output', required=True)
    a = p.parse_args()
    output = Path(a.output)
    output.mkdir(parents=True, exist_ok=True)
    base = ['ffmpeg', '-hide_banner', '-nostdin', '-y', '-loglevel', 'info']

    def run(args, log):
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.monotonic()
        with open(log, 'w') as f:
            proc = subprocess.Popen(base + args, stdout=f, stderr=f)
            try:
                while proc.poll() is None:
                    if os.getloadavg()[0] >= a.max_load:
                        raise RuntimeError('System load reached safety threshold; stopping benchmark')
                    time.sleep(0.5)
                if proc.returncode:
                    raise RuntimeError(f'ffmpeg failed: see {log}')
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        return (after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime,
                time.monotonic() - start)

    raw_args = ['-f', 'rawvideo', '-pixel_format', 'yuv420p', '-video_size', '1920x1080', '-framerate', '30']
    sources = [(Path(s).stem, ['-stream_loop', '-1', '-threads', '2', '-i', s]) for s in a.input]
    sources.append(('motion1080', ['-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30']))
    fields = ['sample', 'preset', 'threads', 'seconds', 'cpu_seconds', 'cpu_cores', 'wall_seconds', 'speed', 'ssim', 'bitrate_kbps', 'load1_end']
    with open(output / 'results.csv', 'w', newline='') as f, tempfile.TemporaryDirectory(prefix='muronaar-x264-') as tmp:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for name, source_args in sources:
            raw = str(Path(tmp) / 'reference.yuv')
            run(source_args + ['-t', str(a.seconds), '-an', '-vf', 'fps=30,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1', '-filter_threads', '1', '-pix_fmt', 'yuv420p', '-threads', '1', '-f', 'rawvideo', raw], output / f'{name}-reference.log')
            for preset in a.presets:
                encoded = str(Path(tmp) / 'encoded.mp4')
                cpu, wall = run(['-re'] + raw_args + ['-i', raw, '-an', '-c:v', 'libx264', '-preset', preset, '-threads', str(a.threads), '-b:v', '4500k', '-maxrate', '5000k', '-bufsize', '9000k', '-profile:v', 'high', '-g', '60', '-bf', '0', encoded], output / f'{name}-{preset}-encode.log')
                quality_log = output / f'{name}-{preset}-ssim.log'
                run(raw_args + ['-threads', '1', '-i', raw, '-threads', '1', '-i', encoded, '-filter_complex_threads', '1', '-lavfi', '[0:v][1:v]ssim', '-an', '-f', 'null', '-'], quality_log)
                ssim = float(re.findall(r'All:([\d.]+)', quality_log.read_text())[-1])
                row = dict(sample=name, preset=preset, threads=a.threads, seconds=a.seconds, cpu_seconds=round(cpu, 3), cpu_cores=round(cpu/a.seconds, 3), wall_seconds=round(wall, 3), speed=round(a.seconds/wall, 3), ssim=ssim, bitrate_kbps=round(Path(encoded).stat().st_size*8/a.seconds/1000, 1), load1_end=os.getloadavg()[0])
                writer.writerow(row)
                f.flush()
                print(json.dumps(row), flush=True)


if __name__ == '__main__':
    main()
