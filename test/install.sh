#!/usr/bin/env bash
# Smoke test: all files are temporary; privileged commands are redirected/mocked.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/muronaar-install-test.XXXXXXXX)
trap 'rm -rf -- "$work"' EXIT
user=$(id -un)
group=$(id -gn)
mkdir -p "$work/source/script" "$work/source/assets" "$work/bin"
cp "$repo/assets/stream-logo.png" "$work/source/assets/"
cp -R "$repo/dist" "$work/source/"
cp "$repo/script/muronaar.liq" "$repo/script/config.example.liq" "$work/source/script/"
export MURONAAR_TEST_ROOT=$work
cat > "$work/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ $# == 1 && $1 == -u ]]; then printf '0\n'; else /usr/bin/id "$@"; fi
EOF
cat > "$work/bin/install" <<'EOF'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
    [[ $arg != /etc/systemd/system/muronaar.service ]] || arg=$MURONAAR_TEST_ROOT/muronaar.service
    args+=("$arg")
done
exec /usr/bin/install "${args[@]}"
EOF
cat > "$work/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MURONAAR_TEST_ROOT/systemctl.log"
EOF
chmod +x "$work/bin/"*
export PATH=$work/bin:$PATH
installer=$work/source/dist/install.sh
key="test-$(cat /proc/sys/kernel/random/uuid)"
run_install() {
    bash "$installer" --user "$user" --group "$group" --dir "$work/app" \
        --hls-dir "$1" --liquidsoap /usr/bin/true --key "$key" > "$work/output.log"
}
run_install "$work/hls"
cmp "$repo/assets/stream-logo.png" "$work/app/assets/stream-logo.png"
[[ $(stat -c '%U:%G' "$work/app/assets/stream-logo.png") == "$user:$group" ]]
[[ -d $work/hls && $(stat -c '%U:%G' "$work/app") == "$user:$group" ]]
[[ $(stat -c '%U:%G' "$work/hls") == "$user:$group" ]]
grep -Fq "output_hls_dir = \"$work/hls\"" "$work/app/config.liq"
grep -Fq 'stream_dir = "/var/lib/muronaar/videos"' "$work/app/config.liq"
grep -Fq "WorkingDirectory=$work/app" "$work/muronaar.service"
grep -Fq "User=$user" "$work/muronaar.service"
grep -Fq "alias $work/hls/;" "$work/app/nginx/hls.conf"
grep -Fq "$key" "$work/app/nginx/http.conf"
if grep -Fq "$key" "$work/app/nginx/rtmp.conf"; then exit 1; fi
if grep -REq '@[A-Z_]+@' "$work/app/nginx" "$work/muronaar.service"; then exit 1; fi
[[ $(stat -c '%a' "$work/app/nginx/http.conf") == 600 ]]
# Existing installed settings win over the example; only the HLS path changes.
printf '\n# private setting preserved\n' >> "$work/app/config.liq"
run_install "$work/hls-new"
grep -Fq '# private setting preserved' "$work/app/config.liq"
grep -Fq "output_hls_dir = \"$work/hls-new\"" "$work/app/config.liq"
[[ $(sort -u "$work/systemctl.log") == daemon-reload ]]
# Reject template injection without touching any installed files.
if bash "$installer" --key 'bad"; return 200;' > "$work/bad.log" 2>&1; then
    printf 'Invalid key was accepted\n' >&2; exit 1
fi
printf 'PASS: example fallback, user/group ownership, custom paths, templates, config preservation and key validation.\n'
