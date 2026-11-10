#!/usr/bin/env liquidsoap
%include "config.liq"

if not list.mem(stream_main_size, [1080, 720, 480, 240]) then
  error.raise(error.invalid, "stream_main_size must be 1080, 720, 480 or 240")
end
program_height = if stream_multi then 1080 else stream_main_size end
program_width = if program_height == 1080 then 1920 elsif program_height == 720 then 1280 elsif program_height == 480 then 854 else 426 end

# Batch three video frames per engine tick to reduce 1080p processing overhead.
settings.frame.duration := 0.1
settings.frame.video.width := program_width
settings.frame.video.height := program_height
settings.frame.video.framerate := 30
settings.frame.audio.samplerate := 48000
settings.frame.audio.channels := 2

# One decoded program feeds the selected encoders on the same clock. Maxrate plus
# audio/mux overhead determines the conservative master BANDWIDTH values.
all_hls_variants = [
  {name="1080", width=1920, height=1080, playlist="stream.m3u8",
   bitrate=video_bitrate, maxrate="5000k", bufsize="9000k", bandwidth=5500000},
  {name="720", width=1280, height=720, playlist=if stream_multi then "stream-720.m3u8" else "stream.m3u8" end,
   bitrate=video_bitrate_720, maxrate="3000k", bufsize="5000k", bandwidth=3400000},
  {name="480", width=854, height=480, playlist=if stream_multi then "stream-480.m3u8" else "stream.m3u8" end,
   bitrate=video_bitrate_480, maxrate="1500k", bufsize="2400k", bandwidth=1800000},
  {name="240", width=426, height=240, playlist=if stream_multi then "stream-240.m3u8" else "stream.m3u8" end,
   bitrate=video_bitrate_240, maxrate="400k", bufsize="700k", bandwidth=600000}
]
hls_variants = if stream_multi then all_hls_variants else
  list.filter(fun (v) -> v.height == stream_main_size, all_hls_variants)
end
# Segment boundaries must match across resolutions for adaptive switching.
hls_gop = int(hls_segment_duration * 30.0)
if hls_gop < 1 then error.raise(error.invalid, "hls_segment_duration must be at least one video frame") end

# Probe the SAME Liquidsoap executable and FFmpeg libraries as the service.
# Listing CLI ffmpeg encoders (or nvidia-smi) does not prove this build can
# initialize NVENC. A short isolated encode catches missing codecs/drivers,
# unsupported GPUs, exhausted sessions and invalid encoder settings.
def probe_video_encoder(codec_name, codec_preset) =
  codec_threads = if codec_name == "libx264" then software_threads else 0 end
  probe_script = file.temp("muronaar-encoder-", ".liq")
  probes = list.map(fun (variant) -> {variant=variant, path=file.temp("muronaar-encoder-", ".ts")}, hls_variants)
  extra_options = if codec_name == "libx264" then ", sc_threshold=0" else ", strict_gop=1" end
  probe_outputs = string.concat(separator="\n", list.map(fun (p) -> "
output.file(
  %ffmpeg(format=\"mpegts\",
    %video(codec=#{string.quote(codec_name)}, preset=#{string.quote(codec_preset)}, threads=#{codec_threads},
      width=#{p.variant.width}, height=#{p.variant.height}, framerate=30, pixel_format=\"yuv420p\",
      b=#{string.quote(p.variant.bitrate)}, maxrate=#{string.quote(p.variant.maxrate)}, bufsize=#{string.quote(p.variant.bufsize)},
      profile=\"high\", g=#{hls_gop}, bf=0, flags=\"+cgop\"#{extra_options})),
  #{string.quote(p.path)}, probe
)", probes))
  probe_code = "
settings.log.level := 1
settings.frame.duration := 0.1
settings.frame.video.width := #{program_width}
settings.frame.video.height := #{program_height}
settings.frame.video.framerate := 30
probe = source({video=source.tracks(blank()).video})
frames = ref(0)
probe.on_frame(synchronous=true, fun () -> begin
  frames := frames() + 1
  if frames() >= 5 then thread.run({shutdown()}) end
end)
#{probe_outputs}
"
  try
    file.write(data=probe_code, probe_script)
    # Liquidsoap's process timeout needs its scheduler, which is not running
    # during startup. Use Ubuntu/coreutils timeout for a real startup deadline.
    result = process.run(
      "exec timeout --signal=TERM --kill-after=2s 20s #{process.quote(liquidsoap.executable)} #{process.quote(probe_script)}"
    )
    usable = result.status == "exit" and result.status.code == 0 and list.for_all(fun (p) -> file.size(p.path) > 0, probes)
    if not usable then
      log("Encoder probe failed for #{codec_name}: #{result.status} (#{result.status.code})")
      details = string.trim(result.stderr)
      if details != "" then log(string.concat(separator="\n", list.prefix(6, string.split(separator="\n", details)))) end
    end
    file.remove(probe_script)
    list.iter(fun (p) -> file.remove(p.path), probes)
    usable
  catch err do
    file.remove(probe_script)
    list.iter(fun (p) -> file.remove(p.path), probes)
    error.raise(err)
  end
end

selected_video_codec =
  if video_encoder == "software" then
    "libx264"
  elsif video_encoder == "auto" or video_encoder == "nvenc" then
    if probe_video_encoder("h264_nvenc", nvenc_preset) then
      "h264_nvenc"
    elsif video_encoder == "auto" then
      log("NVENC is unavailable; falling back to software H.264 (libx264)")
      "libx264"
    else
      error.raise(error.invalid, "NVENC is required by video_encoder but its encode probe failed")
    end
  else
    error.raise(error.invalid, "video_encoder must be auto, nvenc or software")
  end

selected_video_preset =
  if selected_video_codec == "h264_nvenc" then nvenc_preset else software_preset end
selected_video_threads =
  if selected_video_codec == "libx264" then software_threads else 0 end

if selected_video_codec == "libx264" and not probe_video_encoder("libx264", software_preset) then
  error.raise(error.invalid, "Software H.264 (libx264) encode probe failed; no usable video encoder")
end
output_sizes = string.concat(separator="/", list.map(fun (v) -> "#{v.name}p", hls_variants))
log("Video encoder selected: #{selected_video_codec}, preset=#{selected_video_preset}, threads=#{selected_video_threads}, outputs=#{output_sizes}@30")

file.mkdir(parents=true, output_hls_dir)

# One service instance owns this directory. Remove only Muronaar HLS artifacts
# before the muxer starts; never recurse or remove unrelated files/directories.
def cleanup_hls_file(filename) =
  owned =
    r/^(segment-[0-9]+(-(1080|720|480|240))?-[0-9]+\.m4s|init-[0-9]+(-(1080|720|480|240))?\.mp4|video_[0-9]+\.(m4s|mp4|ts)|stream(-720|-480|-240)?\.m3u8|master\.m3u8|video\.m3u8|hls-state\.json)(\.tmp)?$/.test(filename) or
    r/^liq[0-9a-f]+tmp$/.test(filename)
  artifact_path = "#{output_hls_dir}/#{filename}"
  if owned and not file.is_directory(artifact_path) then
    file.remove(artifact_path)
    log("Removed previous HLS artifact: #{filename}")
  end
end
list.iter(cleanup_hls_file, file.ls(output_hls_dir))

# Select ONLY video at the source boundary: files are decoded without audio.
# Sequential, looping directory playlist; pick up directory changes every minute.
files = playlist(
  id="background_files", mode="normal", loop=true,
  reload=60, reload_mode="seconds", prefetch=1,
  stream_dir
)
files = source({video=source.tracks(files).video})
files = video.resize(width=program_width, height=program_height, proportional=true, files)
files = mksafe(files)

# FFmpeg autodetects AAC/ADTS as well as MP3. Both retry independently;
# the AAC URL has priority, with MP3 and finally silence as fallbacks.
def radio_input(source_id, source_url) =
  s = input.http(
    id=source_id, self_sync=true, timeout=10.0, max_buffer=stream_buffer,
    new_track_on_metadata=false, source_url
  )
  s = source({audio=source.tracks(s).audio})
  clock.assign_new(id="#{source_id}_clock", [s])
  buffer(buffer=1.0, max=stream_buffer, s)
end
radio = fallback(
  id="background_radio", track_sensitive=false,
  [radio_input("radio_aac", stream_bgsound),
   radio_input("radio_mp3", "#{stream_bgsound}.mp3"), blank()]
)
background = source.mux.video(video=files, radio)

# Isolate RTMP reads on their own clock: even a half-open connection must
# never block the HLS clock. The bounded bridge becomes unavailable on underrun.
# rw_timeout (microseconds) also detects a publisher that stalls without FIN.
live = input.ffmpeg(
  id="rtmp_ingest", format="live_flv", self_sync=true,
  max_buffer=stream_buffer, poll_delay=1.0,
  int_args=[("listen", 1), ("rw_timeout", int(stream_timeout * 1000000.0))],
  # Fixed internal stream name, not an authentication key. OBS is authorized by nginx.
  "rtmp://0.0.0.0:#{stream_port}/live/muronaar"
)
clock.assign_new(id="rtmp_clock", [live])
live = buffer(id="rtmp_bridge", buffer=1.0, max=stream_buffer, live)
live = video.resize(width=program_width, height=program_height, proportional=true, live)

# Switch decoded frames once for all variants. Each encoder keeps its state
# across source changes; all active outputs share timestamps and GOP cadence.
program = fallback(id="program", track_sensitive=false, [live, background])
clock.assign_new(id="program_clock", sync="cpu", [program])
program.on_track(synchronous=false, fun (_) -> log("Program source/track changed"))

# Delegate segmentation to FFmpeg's HLS muxer. Liquidsoap's MP4 HLS splitter
# put audio samples into EXT-X-MAP init files, breaking late joins in VLC.
# Unique filenames and epoch-based sequences prevent reuse across restarts.
session_number = int(time() * 1000000.0)
session_id = string(session_number)
def make_hls_encoder(v) =
  if selected_video_codec == "h264_nvenc" then
    %ffmpeg(
      format="hls",
      hls_time=hls_segment_duration,
      hls_list_size=hls_segments,
      hls_delete_threshold=hls_segments_overhead,
      hls_segment_type="fmp4",
      hls_flags="delete_segments+independent_segments+temp_file+omit_endlist",
      # All variants start from the same segment sequence and source PTS.
      start_number=session_number,
      hls_fmp4_init_filename="init-#{session_id}-#{v.name}.mp4",
      hls_segment_filename="#{output_hls_dir}/segment-#{session_id}-#{v.name}-%09d.m4s",
      %audio(codec="aac", b="128k", ar=48000, channels=2),
      %video(codec=selected_video_codec, b=v.bitrate, maxrate=v.maxrate, bufsize=v.bufsize,
        width=v.width, height=v.height,
        preset=selected_video_preset, threads=selected_video_threads, profile="high",
        g=hls_gop, bf=0, flags="+cgop", strict_gop=1,
        framerate=30, pixel_format="yuv420p")
    )
  else
    %ffmpeg(
      format="hls",
      hls_time=hls_segment_duration,
      hls_list_size=hls_segments,
      hls_delete_threshold=hls_segments_overhead,
      hls_segment_type="fmp4",
      hls_flags="delete_segments+independent_segments+temp_file+omit_endlist",
      # All variants start from the same segment sequence and source PTS.
      start_number=session_number,
      hls_fmp4_init_filename="init-#{session_id}-#{v.name}.mp4",
      hls_segment_filename="#{output_hls_dir}/segment-#{session_id}-#{v.name}-%09d.m4s",
      %audio(codec="aac", b="128k", ar=48000, channels=2),
      %video(codec=selected_video_codec, b=v.bitrate, maxrate=v.maxrate, bufsize=v.bufsize,
        width=v.width, height=v.height,
        preset=selected_video_preset, threads=selected_video_threads, profile="high",
        g=hls_gop, bf=0, flags="+cgop", sc_threshold=0,
        framerate=30, pixel_format="yuv420p")
    )
  end
end

# Keep the file-only entry point; HTTP and filesystem use the same muxers.
def start_hls_muxer(s) =
  list.iter(fun (v) -> output.url(
    id="hls_#{v.name}", restart_delay=null,
    url="#{output_hls_dir}/#{v.playlist}", make_hls_encoder(v), s
  ), hls_variants)
  master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n" ^
    string.concat(list.map(fun (v) ->
      "#EXT-X-STREAM-INF:BANDWIDTH=#{v.bandwidth},RESOLUTION=#{v.width}x#{v.height},FRAME-RATE=30.000\n#{v.playlist}\n",
      hls_variants))
  file.write(data=master, "#{output_hls_dir}/master.m3u8")
end

# Finish and close file reads before handing a response to Harbor. Otherwise
# a disconnected client can leave a file.read getter open until garbage collection.
# Accumulate chunks once, avoiding repeated concatenation of a whole segment.
def read_hls_data(artifact_path) =
  fd = file.open(write=false, artifact_path)
  try
    chunks = ref([])
    chunk = ref(fd.read())
    while chunk() != "" do
      chunks := [chunk(), ...chunks()]
      chunk := fd.read()
    end
    fd.close()
    string.concat(list.rev(chunks()))
  catch err do
    if not fd.closed() then fd.close() end
    error.raise(err)
  end
end

# Built-in Harbor HTTP origin. Serve only published HLS filenames, never
# temporary files, directory listings or arbitrary filesystem paths.
def serve_hls(http_request, response) =
  response.header("Access-Control-Allow-Origin", "*")
  response.header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
  cache_policy = ref("no-store")
  filename = http_request.query["filename"]
  allowed = r/^(master\.m3u8|stream(-720|-480|-240)?\.m3u8|segment-[0-9]+(-(1080|720|480|240))?-[0-9]+\.m4s|init-[0-9]+(-(1080|720|480|240))?\.mp4)$/.test(filename)
  artifact_path = "#{output_hls_dir}/#{filename}"
  if not allowed then
    response.status_code(404)
  elsif http_request.method == "OPTIONS" then
    response.status_code(204)
  else
    try
      if r/\.m3u8$/.test(filename) then
        # Read the playlist atomically into a string: its size can change
        # between stat() and open() as FFmpeg publishes a new version.
        playlist_data = read_hls_data(artifact_path)
        response.content_type("application/vnd.apple.mpegurl")
        # Harbor frames getter responses with chunked transfer encoding.
        # A manual Content-Length conflicts with it and nginx rejects the response.
        if http_request.method == "GET" then response.data(string.getter.single(playlist_data)) end
      else
        # The origin buffers one short immutable fragment per GET; nginx
        # caches it, so client disconnects never hold file descriptors open.
        if http_request.method == "GET" then
          artifact_data = read_hls_data(artifact_path)
          response.data(string.getter.single(artifact_data))
        else
          ignore(file.size(artifact_path))
        end
        response.content_type("video/mp4")
        cache_policy := "public, max-age=600, immutable"
      end
    catch _ do
      # A segment may expire between receiving the request and opening it.
      response.status_code(404)
      cache_policy := "no-store"
    end
  end
  # response.header appends headers; emit exactly one cache policy per response.
  response.header("Cache-Control", cache_policy())
end

def output_hls_http(s) =
  def register_hls_method(method) =
    harbor.http.register(port=stream_hls_port, method=method, "/:filename", serve_hls)
  end
  list.iter(register_hls_method, ["GET", "HEAD", "OPTIONS"])
  start_hls_muxer(s)
end

# Active: write HLS files; nginx serves output_hls_dir directly.
start_hls_muxer(program)

# Optional built-in HTTP origin (disabled). To use it, comment out the call
# above and uncomment the next line; stream_hls_port sets its listener port.
# output_hls_http(program)
