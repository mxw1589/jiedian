#!/bin/sh
# Regression test: interactive port input must be read in the current shell.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LIB=$(mktemp)
trap 'rm -f "$LIB"' EXIT HUP INT TERM

cat > "$LIB" <<'STUBS'
ANYTLS_PORT=10001
WS_PORT=10002
REALITY_PORT=10003
NAIVE_PORT=10004
ANYREALITY_PORT=10005
XHTTP_PORT=10006
SNELL_PORT=""
SS2022_PORT=""
warn() { printf '[WARN] %s\n' "$*" >&2; }
trim_value() { printf '%s\n' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]
}
normalize_optional_port() {
    value=$(trim_value "$1")
    [ -n "$value" ] || return 0
    valid_port "$value" || return 1
    printf '%s\n' "$value"
}
port_listening() { return 1; }
pick_random_range_port() { printf '45678\n'; }
STUBS
sed -n '/^choose_free_added_port() {/,/^}/p' "$ROOT/sb-manager-debian-alpine.sh" >> "$LIB"

printf '12345\n' | sh -c '. "$1"; choose_free_added_port; [ "$CHOSEN_PORT" = 12345 ]' sh "$LIB" >/dev/null
printf '\n' | sh -c '. "$1"; choose_free_added_port; [ "$CHOSEN_PORT" = 45678 ]' sh "$LIB" >/dev/null
if sh -c '. "$1"; choose_free_added_port' sh "$LIB" </dev/null >/dev/null 2>&1; then
    echo 'FAIL: EOF should cancel port selection.' >&2
    exit 1
fi

echo 'PASS: manual port, automatic port, and EOF cancellation.'
