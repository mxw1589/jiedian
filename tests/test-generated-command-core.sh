#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'prepare-web-config-core' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'SB_CORE_PREPARED=1 /usr/local/sbin/sb-manager install-web-config' "$ROOT/manager.html"
grep -q 'prepare-web-config-core "$CFG"' "$ROOT/manager.html"
grep -q 'if \[ "$ENABLE_XHTTP" = 1 \]; then' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'install_xray_core' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'v1.0.9; selectable IPv4, IPv6 or dual-stack node display from web-generated commands' "$ROOT/manager.html"
grep -q '^# v1.0.9; selectable IPv4, IPv6 or dual-stack node display from web-generated commands$' "$ROOT/sb-manager-debian-alpine.sh"
grep -q 'sb-manager.pre-script' "$ROOT/sb-manager-debian-alpine.sh"
grep -q '不是本项目管理器' "$ROOT/sb-manager-debian-alpine.sh"
echo 'PASS: installer bootstraps protocol-specific cores and protects the existing manager executable.'

grep -q 'sb-manager nodes .*node_family' "$ROOT/manager.html"
grep -q '46|64)' "$ROOT/sb-manager-debian-alpine.sh"
grep -q '用法：sb-manager nodes \[4|6|46\]' "$ROOT/sb-manager-debian-alpine.sh"
echo 'PASS: web command selects IPv4, IPv6 or merged dual-stack output through the repository manager.'
