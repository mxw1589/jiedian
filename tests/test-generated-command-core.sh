#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'prepare-web-config-core' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'SB_CORE_PREPARED=1 /usr/local/sbin/sb-manager install-web-config' "$ROOT/manager.html"
grep -q 'prepare-web-config-core "$CFG"' "$ROOT/manager.html"
grep -q 'if \[ "$ENABLE_XHTTP" = 1 \]; then' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'install_xray_core' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'v1.0.8; compact IPv4/IPv6 node lists and per-family client configs' "$ROOT/manager.html"
grep -q '^# v1.0.8; compact IPv4/IPv6 node lists and per-family client configs$' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'sb-manager.pre-script' "$ROOT/sb-manager-debian-alpine.sh"
grep -q '不是本项目管理器' "$ROOT/sb-manager-debian-alpine.sh"
echo 'PASS: installer bootstraps protocol-specific cores and protects the existing manager executable.'
