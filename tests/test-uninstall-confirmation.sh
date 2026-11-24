#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT HUP INT TERM
sed -n '/^uninstall_manager() {/,/^}/p' "$SCRIPT" > "$TMP"
[ -s "$TMP" ] || { echo 'FAIL: uninstall_manager function not found.' >&2; exit 1; }
# Evaluate only the function with root/message helpers stubbed; a negative answer must return before any cleanup.
output=$(printf 'NO\n' | sh -c '
need_root() { :; }
msg() { printf "%s\\n" "$*"; }
. "$1"
uninstall_manager
' sh "$TMP")
printf '%s\n' "$output" | grep -q '已取消卸载'
if printf '%s\n' "$output" | grep -q '正在删除 sing-box 配置'; then
  echo 'FAIL: uninstall continued after a negative confirmation.' >&2
  exit 1
fi
printf '%s\n' 'PASS: uninstall aborts safely unless the user confirms with YES.'
