#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'prepare-web-config-core' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'SB_CORE_PREPARED=1 /usr/local/sbin/sb-manager install-web-config' "$ROOT/manager.html"
grep -q 'prepare-web-config-core "$CFG"' "$ROOT/manager.html"
grep -q 'if \[ "$ENABLE_XHTTP" = 1 \]; then' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'install_xray_core' "$ROOT/sb-manager-debian-alpine.sh"
echo 'PASS: generated installer bootstraps protocol-specific cores before protocol configuration.'
