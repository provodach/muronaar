# Liquidsoap 2.4.6. Paths are absolute; restart the service after editing.
stream_dir = "/var/lib/muronaar/videos"
stream_bgsound = "https://station.waveradio.org/provodach"
stream_port = 8900
# Plain HTTP origin for HLS (no TLS).
stream_hls_port = 8088
output_hls_dir = "/tmp/muronaar"

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
# auto: try NVENC, then libx264; nvenc: require GPU; software: force CPU.
video_encoder = "auto"
nvenc_preset = "p4"
software_preset = "veryfast"
# Limit x264 encoder worker threads (not a hard CPU quota for the service).
software_threads = 2
