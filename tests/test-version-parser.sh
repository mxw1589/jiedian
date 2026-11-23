#!/bin/sh
# Test tolerant parsing of upstream and Alpine sing-box version output.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=$(mktemp -d)
trap 'rm -rf "$LIB"' EXIT HUP INT TERM
sed -n '/^sing_box_version_from() {/,/^}/p' "$ROOT/sb-manager-debian-alpine.sh" > "$LIB/parser.sh"
cat > "$LIB/sing-box" <<'BIN'
#!/bin/sh
printf '%s\n' 'sing-box version 1.14.4 (go1.25.4 linux/amd64)'
BIN
chmod +x "$LIB/sing-box"
[ "$(sh -c '. "$1"; sing_box_version_from "$2"' sh "$LIB/parser.sh" "$LIB/sing-box")" = 1.14.4 ]
cat > "$LIB/sing-box" <<'BIN'
#!/bin/sh
printf '%s\n' 'sing-box version v1.13.2'
BIN
chmod +x "$LIB/sing-box"
[ "$(sh -c '. "$1"; sing_box_version_from "$2"' sh "$LIB/parser.sh" "$LIB/sing-box")" = 1.13.2 ]
cat > "$LIB/sing-box" <<'BIN'
#!/bin/sh
printf '%s\n' 'unexpected output'
BIN
chmod +x "$LIB/sing-box"
if sh -c '. "$1"; sing_box_version_from "$2"' sh "$LIB/parser.sh" "$LIB/sing-box" >/dev/null 2>&1; then
  echo 'FAIL: unrecognized version must not be accepted' >&2; exit 1
fi
echo 'PASS: sing-box version parser accepts normal/v-prefixed output and rejects unknown output.'
