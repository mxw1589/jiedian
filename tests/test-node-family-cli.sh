#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/sb-manager-debian-alpine.sh"
grep -Fq 'if [ "${1:-}" = nodes ]; then' "$SCRIPT"
grep -Fq '46|64)' "$SCRIPT"
grep -Fq 'cat "$APP_DIR/nodes-dualstack.txt"' "$SCRIPT"
grep -Fq 'cat "$APP_DIR/nodes-ipv4.txt"' "$SCRIPT"
grep -Fq 'cat "$APP_DIR/nodes-ipv6.txt"' "$SCRIPT"
grep -Fq 'sb-manager nodes' "$ROOT/manager.html"
echo 'PASS: CLI supports family-specific and merged dual-stack node display.'
