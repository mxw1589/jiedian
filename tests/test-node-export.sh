#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
TMP="${TMPDIR:-/tmp}/jiedian-node-test-$$"
trap 'rm -f "$TMP"' EXIT HUP INT TERM
{
  sed -n '/^node_tag() {/,/^}/p' "$SCRIPT"
  sed -n '/^uri_host() {/,/^}/p' "$SCRIPT"
  sed -n '/^show_ss2022_node() {/,/^}/p' "$SCRIPT"
  cat <<'EOF'
NODE_PREFIX=HK
SS2022_PORT=8388
SS2022_PASSWORD=YWJjZGVmZ2hpamtsbW5vcA==
SS2022_METHOD=2022-blake3-aes-128-gcm
show_ss2022_node IPv4 203.0.113.7
show_ss2022_node IPv6 2001:db8::7
EOF
} > "$TMP"
OUT=$(sh "$TMP")
printf '%s\n' "$OUT" | grep -Fq 'HK-ipv4-203.0.113.7-ss2022'
printf '%s\n' "$OUT" | grep -Fq 'HK-ipv6-2001:db8::7-ss2022'
printf '%s\n' "$OUT" | grep -Fq '@[2001:db8::7]:8388#'
printf '%s\n' "$OUT" | grep -Fq 'ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206WVdKalpHVm1aMmhwYW10c2JXNXZjQT09@203.0.113.7:8388#'
echo 'PASS: IPv4 + IPv6 node output, prefix placement, SS2022 SIP002 Base64URL link'
