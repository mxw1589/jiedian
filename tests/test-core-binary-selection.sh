#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=$(mktemp -d)
trap 'rm -rf "$LIB"' EXIT HUP INT TERM
sed -n '/^sing_box_version_from() {/,/^}/p; /^version_at_least() {/,/^}/p; /^resolve_sing_box_binary() {/,/^}/p' "$ROOT/sb-manager-debian-alpine.sh" > "$LIB/functions.sh"
mkdir -p "$LIB/usr/local/bin" "$LIB/usr/bin"
cat > "$LIB/usr/local/bin/sing-box" <<'BIN'
#!/bin/sh
printf '%s\n' 'sing-box version 1.13.0 (old local build)'
BIN
cat > "$LIB/usr/bin/sing-box" <<'BIN'
#!/bin/sh
printf '%s\n' 'sing-box version 1.14.4 (new package build)'
BIN
chmod +x "$LIB/usr/local/bin/sing-box" "$LIB/usr/bin/sing-box"
# Rewrite absolute paths only in the extracted test copy.
sed -i "s#/usr/local/bin/sing-box#$LIB/usr/local/bin/sing-box#g; s#/usr/bin/sing-box#$LIB/usr/bin/sing-box#g" "$LIB/functions.sh"
selected=$(sh -c '. "$1"; resolve_sing_box_binary' sh "$LIB/functions.sh")
[ "$selected" = "$LIB/usr/bin/sing-box" ]
echo 'PASS: newest parseable sing-box binary wins over PATH preference.'
