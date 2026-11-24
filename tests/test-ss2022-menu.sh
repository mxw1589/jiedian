#!/bin/sh
# Ensure the dedicated menu 24 reaches SS2022-only operations, not the full protocol menu.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
cat >"$TMP/run.sh" <<'STUB'
#!/bin/sh
set -eu
ENABLE_SS2022=1
SS2022_PORT=23456
SS2022_METHOD=2022-blake3-aes-256-gcm
modify_ss2022() { echo modify >> "$CALLS"; }
remove_ss2022() { echo remove >> "$CALLS"; ENABLE_SS2022=0; }
add_ss2022() { echo add >> "$CALLS"; ENABLE_SS2022=1; }
warn() { :; }
STUB
sed -n '/^manage_ss2022() {/,/^}/p' "$SCRIPT" >> "$TMP/run.sh"
printf '\nmanage_ss2022\n' >> "$TMP/run.sh"
printf '2\n0\n' | CALLS="$TMP/calls" sh "$TMP/run.sh" >/dev/null
grep -qx remove "$TMP/calls"
# The main menu's option 24 must route to the dedicated function.
grep -Fq '24) manage_ss2022 ;;' "$SCRIPT"
if grep -Fq '24) manage_all_protocols ;;' "$SCRIPT"; then
  echo 'FAIL: menu 24 still opens the full protocol manager.' >&2
  exit 1
fi
echo 'PASS: SS2022 dedicated menu routes to SS2022 add/remove/modify handlers.'
