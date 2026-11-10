#!/usr/bin/env bash
set -euo pipefail

user=muronaar
group=service
dir=/opt/muronaar
hls_dir=/tmp/muronaar
key=
liquidsoap=$(command -v liquidsoap || true)
dist=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'EOF'
Usage: sudo dist/install.sh --key KEY [options]
  --user NAME        Existing service user (default: muronaar)
  --group NAME       Existing service group (default: service)
  --dir PATH         Installation directory (default: /opt/muronaar)
  --hls-dir PATH     HLS segments directory (default: /tmp/muronaar)
  --key KEY          OBS stream key (required; letters, digits, dot, underscore, hyphen)
  --liquidsoap PATH  Liquidsoap executable (default: liquidsoap in PATH)
  -h, --help         Show help

Copies files, renders nginx/systemd templates and reloads systemd definitions.
Does not create accounts, change nginx settings or start/restart services.
Preserves existing config settings except output_hls_dir, set by --hls-dir.
EOF
}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --user|--group|--dir|--hls-dir|--key|--liquidsoap)
            (($# >= 2)) || die "Missing value for $1"
            case "$1" in
                --user) user=$2 ;; --group) group=$2 ;; --dir) dir=$2 ;;
                --hls-dir) hls_dir=$2 ;; --key) key=$2 ;; --liquidsoap) liquidsoap=$2 ;;
            esac
            shift 2 ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ $key =~ ^[A-Za-z0-9_.-]{1,256}$ ]] || die 'Supply --key using 1-256 letters, digits or ._-'
[[ $user =~ ^[A-Za-z_][A-Za-z0-9_-]*$ && $group =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die 'Invalid user/group name'
# Simple paths keep substitutions valid in Liquidsoap, nginx and systemd.
for path in "$dir" "$hls_dir" "$liquidsoap"; do
    [[ $path =~ ^/[A-Za-z0-9_./-]+$ && $path != / ]] || die 'Use absolute paths without spaces or special characters'
done
[[ -x $liquidsoap ]] || die 'Liquidsoap not found; supply --liquidsoap /absolute/path'
[[ $(id -u) == 0 ]] || die 'Run this installer with sudo'
id "$user" >/dev/null 2>&1 || die "User does not exist: $user"
getent group "$group" >/dev/null || die "Group does not exist: $group"

config=$dist/../script/config.liq
[[ -f $config ]] || config=$dist/../script/config.example.liq
[[ ! -f $dir/config.liq ]] || config=$dir/config.liq
port() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/p" "$config"; }
ingest_port=$(port stream_port)
hls_port=$(port stream_hls_port)
for port in "$ingest_port" "$hls_port"; do
    if [[ ! $port =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
        die 'Use literal port numbers in config.liq'
    fi
done
ingest_port=$((10#$ingest_port))
hls_port=$((10#$hls_port))
[[ $ingest_port != "$hls_port" && $ingest_port != 1935 && $hls_port != 1935 && $ingest_port != 18935 && $hls_port != 18935 ]] || die 'HLS/ingest ports conflict with each other or nginx'

work=$(mktemp -d /tmp/muronaar-install.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
render() {
    sed -e "s|@USER@|$user|g" -e "s|@GROUP@|$group|g" \
        -e "s|@INSTALL_DIR@|$dir|g" -e "s|@LIQUIDSOAP@|$liquidsoap|g" \
        -e "s|@HLS_DIR@|$hls_dir|g" -e "s|@STREAM_KEY@|$key|g" -e 's|@RTMP_PORT@|1935|g' -e 's|@AUTH_PORT@|18935|g' \
        -e "s|@INGEST_PORT@|$ingest_port|g" -e "s|@HLS_PORT@|$hls_port|g" "$1"
}
# Read the config before replacing it; updates also work when it is already installed.
sed -E "s|^[[:space:]]*output_hls_dir[[:space:]]*=.*$|output_hls_dir = \"$hls_dir\"|" "$config" > "$work/config.liq"
install -d -o "$user" -g "$group" -m 0755 "$dir" "$hls_dir"
install -o "$user" -g "$group" -m 0644 "$dist/../script/muronaar.liq" "$dir/muronaar.liq"
install -o "$user" -g "$group" -m 0640 "$work/config.liq" "$dir/config.liq"
install -d -o "$user" -g "$group" -m 0700 "$dir/nginx"
for template in "$dist"/nginx/*.conf; do
    render "$template" > "$work/$(basename -- "$template")"
    install -o "$user" -g "$group" -m 0600 "$work/$(basename -- "$template")" "$dir/nginx/"
done
render "$dist/muronaar.service" > "$work/muronaar.service"
install -m 0644 "$work/muronaar.service" /etc/systemd/system/muronaar.service
systemctl daemon-reload
printf 'Installed in %s (%s:%s). HLS files: %s\n' "$dir" "$user" "$group" "$hls_dir"
printf 'Connect %s/nginx to nginx.conf/vhost, then validate nginx and start Muronaar.\n' "$dir"
