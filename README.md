<p align="center">
  <img src="assets/logo.png" alt="Muronaar logo" width="100">
</p>

<h1 align="center">Muronaar</h1>

<blockquote>
  <p align="center"><em>Muronaar · n. · “perception” — from Ancient Rekrevian language</em></p>
</blockquote>

Muronaar is a continuous video broadcast service built with Liquidsoap 2.4.6.
It loops videos from a directory, discards their original audio and adds an
Internet radio soundtrack. When an OBS publisher connects through nginx RTMP,
its video **and audio** replace the background. Disconnecting returns to the
background without restarting the HLS outputs.

One decoded program feeds three H.264 encoders: 1080p, 720p and 480p at 30 fps,
with AAC 128 kbit/s stereo audio. Video is fitted proportionally with letterboxing.
NVENC is preferred; if unavailable, `auto` falls back to CPU encoding with libx264.
A startup probe checks three concurrent encoding sessions using the same
Liquidsoap executable and FFmpeg libraries as the service.

```text
video library + radio ─┐
                       ├─ Liquidsoap ─ HTTP HLS ─ nginx cache ─ viewers
OBS ─ nginx RTMP/auth ─┘
```

## Repository layout

```text
script/
  muronaar.liq           Broadcast, encoder detection and HTTP HLS origin
  config.example.liq     Public example configuration
  config.liq             Your private settings (ignored by git)
dist/
  install.sh             Installer for /opt/muronaar and systemd
  muronaar.service       systemd unit template
  nginx/                 Key-free nginx templates for RTMP, auth and HLS cache
test/
  benchmark_presets.py   Optional CPU/quality benchmark
  install.sh             Installer smoke test (temporary files only)
```

## Requirements

Use Linux with systemd, Bash, sed, coreutils (`timeout`), Liquidsoap 2.4.6
with FFmpeg support, nginx and the nginx RTMP module. FFmpeg CLI is useful for
diagnostics and benchmarks; Liquidsoap encodes with its own linked FFmpeg libraries.
For H.264, that build must provide `h264_nvenc` or `libx264`; AAC encoding is also required.

On Ubuntu, install the available nginx packages with:

```bash
sudo apt-get install nginx libnginx-mod-rtmp
```

Install a Liquidsoap 2.4.6 build with the required codecs separately. An encoder
listed by the standalone `ffmpeg` command does not guarantee it exists in Liquidsoap.
NVIDIA encoding also requires a compatible GPU and working driver. Ensure the
service identity has access to the executable, its libraries and GPU devices.

## Installation

Run from a checkout. Enter your OBS key interactively, then pass it to the installer:

```bash
read -rsp 'OBS stream key: ' OBS_STREAM_KEY
printf '\n'
sudo ./dist/install.sh --key "$OBS_STREAM_KEY"
unset OBS_STREAM_KEY
```

The default identity is **`muronaar:service`**. Both the user and group must
already exist. The installer does not create accounts.

For an existing `service:service` account, use this instead of the default invocation:

```bash
read -rsp 'OBS stream key: ' OBS_STREAM_KEY
printf '\n'
sudo ./dist/install.sh --user service --group service \
  --dir /opt/muronaar --hls-dir /tmp/muronaar --key "$OBS_STREAM_KEY"
unset OBS_STREAM_KEY
```

| Option | Default | Purpose |
| --- | --- | --- |
| `--user NAME` | `muronaar` | Existing service user |
| `--group NAME` | `service` | Existing service group |
| `--dir PATH` | `/opt/muronaar` | Installation directory; created and owned by the selected user/group |
| `--hls-dir PATH` | `/tmp/muronaar` | HLS working directory; created and owned by the same user/group |
| `--key KEY` | Required | OBS key, 1–256 characters from `A-Z a-z 0-9 . _ -` |
| `--liquidsoap PATH` | `liquidsoap` in PATH | Liquidsoap executable, including a custom OPAM build |
| `--help` | — | Show usage |

Paths must be absolute and contain no spaces or special characters.
The Bash installer copies files and substitutes nginx/systemd templates. It
installs `muronaar.liq`, `config.liq` and `nginx/` into `--dir`, and the generated
unit into `/etc/systemd/system/muronaar.service`. Internal ports come from the
selected config; nginx's public RTMP/auth ports remain 1935/18935.

Configuration is selected in this order:

1. Existing `--dir/config.liq` (updates).
2. Your local `script/config.liq`, if present.
3. `script/config.example.liq`, copied as the installed `config.liq`.

All existing settings are preserved **except `output_hls_dir`**, which is always
set to `--hls-dir`. You can also copy the example to `script/config.liq` and edit
it before installation. That private file is excluded by `.gitignore`; if already
tracked in an existing repository, untrack it with `git rm --cached script/config.liq`.

The installer does not create the video library or change existing media ownership.
Create/configure the library yourself and grant the service user read/traverse
access. It does not install packages, make backups, enable nginx snippets or
start/restart services. Back up existing files before updating.

nginx's disk cache remains separate at `/var/cache/nginx/muronaar_hls`. HLS
segments default to `/tmp/muronaar`, so on hosts with tmpfs-backed `/tmp` they
stay in RAM. The installer does not mount tmpfs; check your host with
`findmnt -T /tmp/muronaar` after creating the directory.

After configuring nginx and reviewing the installed config:

```bash
sudo systemctl enable --now muronaar
sudo journalctl -u muronaar -f
```

On updates, rerun the installer and restart Muronaar yourself. Reload nginx when
changing the key, directory or ports. Changing `--key` does not affect Liquidsoap.

## Configuration

Edit `--dir/config.liq`, then restart `muronaar`. Start from
`script/config.example.liq` if you do not have private settings. Use literal
integers for `stream_port` and `stream_hls_port` so the installer can read them.

| Setting | Shipped default | Meaning |
| --- | --- | --- |
| `stream_dir` | `/var/lib/muronaar/videos` | Background video library; sequential looping playlist, refreshed every 60 seconds |
| `stream_bgsound` | `https://station.waveradio.org/provodach` | Background radio URL; AAC first, URL + `.mp3` as a fallback |
| `stream_port` | `8900` | Internal Liquidsoap RTMP listener |
| `stream_hls_port` | `8088` | Plain HTTP HLS origin |
| `output_hls_dir` | `/tmp/muronaar` | Working HLS files, also used in file-only mode |
| `stream_buffer` | `3.0` | Maximum buffering for network-source bridges, seconds |
| `stream_timeout` | `5.0` | Stalled RTMP publisher read timeout, seconds |
| `hls_segment_duration` | `2.0` | Target segment duration and GOP duration |
| `hls_segments` | `20` | Playlist window, per quality |
| `hls_segments_overhead` | `2` | Expired segments retained for lagging clients, per quality |
| `video_bitrate` | `"4500k"` | 1080p target video bitrate |
| `video_bitrate_720` | `"2500k"` | 720p target video bitrate |
| `video_bitrate_480` | `"1200k"` | 480p target video bitrate |
| `video_encoder` | `"auto"` | `auto`: NVENC then libx264; `nvenc`: require GPU; `software`: CPU only |
| `nvenc_preset` | `"p4"` | NVENC preset |
| `software_preset` | `"veryfast"` | libx264 preset |
| `software_threads` | `2` | x264 worker threads **per encoder**, not a total CPU quota |

Use the same user/group when updating. Existing video files must be readable,
all parent directories traversable and the HLS directory writable by that identity.
Missing videos produce black video; unavailable radio eventually falls back to silence.

Segments use fragmented MP4 (`.m4s` plus an init `.mp4`). Each quality retains
about 22 completed segments by default. Startup removes only Muronaar-owned HLS
artifacts from `output_hls_dir`; unrelated files/subdirectories remain. Do not
point multiple running instances at one HLS directory, or put HLS output inside
the video library.

There is no OBS key in Liquidsoap. nginx checks the key and pushes the authorized
stream to `/live/muronaar`, a fixed internal stream name. If you change either
Liquidsoap port, rerun the installer and reload nginx after updating the service.

## nginx

Templates in `dist/nginx/` contain placeholders, **no configured credentials**.
Use the rendered files in `--dir/nginx/`, not the templates directly. The examples
below assume the default `/opt/muronaar`; use your chosen directory otherwise.
Create the dedicated nginx cache directory for your nginx worker user if needed
(for example, `sudo install -d -o www-data -g www-data /var/cache/nginx/muronaar_hls`).

Inside nginx.conf's existing `http {}` block, include the cache zone/auth server:

```nginx
include /opt/muronaar/nginx/http.conf;
```

Outside `http {}`, at the main level of nginx.conf, include RTMP:

```nginx
include /opt/muronaar/nginx/rtmp.conf;
```

Inside your public HTTP/HTTPS virtual host, add:

```nginx
server {
    listen 80;
    server_name video.example.org;
    include /opt/muronaar/nginx/hls.conf;
    # Keep/add your normal HTTPS listener and certificates here.
}
```

If you already have a virtual host, add only the include to that server block.
On Ubuntu the RTMP package normally loads its module through `modules-enabled`.
Do not put the RTMP include in `conf.d` when that directory is included inside
`http {}`. Remove any older Muronaar snippets first to avoid duplicate locations,
cache zones or listeners. Validate and reload:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

nginx strips `/vod/` before proxying to the HTTP origin. The four playlists are
cached for one second; immutable init/segments for ten minutes; errors are not
cached. `X-Cache-Status` shows `MISS`, `HIT` or `EXPIRED`. HTTP buffering stays on
for the cache. RTMP is a separate live relay; HTTP buffering directives do not
apply, and nginx does not transcode or record it.

Publish TCP 1935 (or `--rtmp-port`) through your router/firewall to nginx. Keep
Liquidsoap's ingest/HLS ports private: direct ingest bypasses nginx authorization.
The auth callback listens only on loopback. These templates assume nginx and
Liquidsoap run on the same host; for separate hosts, adjust the upstream addresses.

## OBS and viewing

In OBS, select **Custom** under Settings → Stream:

- **Server:** `rtmp://video.example.org/inlive` (add `:PORT` for a non-default port).
- **Stream Key:** the value supplied through `--key`.
- Use H.264 video, AAC audio and a two-second keyframe interval.
- Publish the audio you want viewers to hear. Desktop capture can unintentionally
  include the radio playing in your monitoring player.

| Public path | Output |
| --- | --- |
| `/vod/stream.m3u8` | 1920×1080, fixed quality |
| `/vod/stream-720.m3u8` | 1280×720, fixed quality |
| `/vod/stream-480.m3u8` | 854×480, fixed quality |
| `/vod/master.m3u8` | Adaptive selection |

The master lists resolutions, bandwidth estimates and media-playlist URLs.
An adaptive HLS player downloads one quality at a time and can switch at aligned
segment boundaries. All three variants are encoded continuously regardless of
viewer count. Use a compatible HLS player; browsers without native HLS need a
player such as hls.js. A direct media-playlist URL fixes the quality.

NVENC requires three concurrent sessions. CPU fallback is functional, but three
outputs can exceed a small CPU's real-time budget. Thread count does not cap CPU
usage. Monitor `Latency is too high` in the journal; reduce preset complexity if needed.

## Development checks

```bash
bash -n dist/install.sh
bash test/install.sh
[[ -f script/config.liq ]] || cp script/config.example.liq script/config.liq
liquidsoap --check script/muronaar.liq
```

The installer smoke test uses temporary directories outside the checkout.
Local configuration, Python caches and generated/test-output directories are
excluded by `.gitignore`. The optional Python script `test/benchmark_presets.py`
measures software encoder CPU cost and SSIM; Python is not used by the installer.

References: [Liquidsoap 2.4.6](https://www.liquidsoap.info/doc-2.4.6/documentation),
[nginx HTTP proxy/cache](https://nginx.org/en/docs/http/ngx_http_proxy_module.html),
[nginx RTMP directives](https://github.com/arut/nginx-rtmp-module/wiki/Directives).
