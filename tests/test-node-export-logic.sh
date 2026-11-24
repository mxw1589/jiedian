#!/bin/sh
# Regression checks for SS2022 dual-stack export and occupied-port ownership.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
grep -Fq 'PREVIOUS_SS2022_PORT=""' "$SCRIPT"
grep -Fq '"$PREVIOUS_SNELL_PORT" "$PREVIOUS_SS2022_PORT"' "$SCRIPT"
grep -Fq 'PREVIOUS_SS2022_PORT=$old_ss2022' "$SCRIPT"
grep -Fq 'node_tag IPv4 "$ORIGIN_ADDR" ss2022' "$SCRIPT"
grep -Fq 'node_tag IPv6 "$ORIGIN_IPV6" ss2022' "$SCRIPT"
grep -Fq 'node_tag IPv4 "$ORIGIN_ADDR" snell' "$SCRIPT"
grep -Fq 'node_tag IPv6 "$ORIGIN_IPV6" snell' "$SCRIPT"
grep -Fq 'ENABLE_SNELL" = 0 ] && [ "$ENABLE_SS2022" = 0' "$SCRIPT"
sh -n "$SCRIPT"
echo 'PASS: SS2022 port ownership and dual-stack SS2022/Snell node export checks.'
