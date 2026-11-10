# Liquidsoap 2.4.6. Paths are absolute; restart the service after editing.
stream_dir = "/var/lib/muronaar/videos"
stream_bgsound = "https://station.waveradio.org/provodach"
stream_port = 8900
# Optional built-in HTTP origin port (disabled in file-only mode).
stream_hls_port = 8088
output_hls_dir = "/tmp/muronaar"

# true: 1080p + 720p + 480p + 240p; false: one stream at stream_main_size.
stream_multi = false
stream_main_size = 1080

# RTMP jitter buffer / dead publisher timeout (seconds).
stream_buffer = 3.0
stream_timeout = 5.0
hls_segment_duration = 2.0
hls_segments = 20
# Keep two expired segments for clients reading a slightly older playlist.
hls_segments_overhead = 2
video_bitrate = "4500k"
video_bitrate_720 = "2500k"
video_bitrate_480 = "1200k"
video_bitrate_240 = "350k"
# auto: try NVENC, then libx264; nvenc: require GPU; software: force CPU.
video_encoder = "auto"
nvenc_preset = "p4"
software_preset = "veryfast"
# Limit x264 encoder worker threads (not a hard CPU quota for the service).
software_threads = 2
