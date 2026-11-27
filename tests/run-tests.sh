#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
js_tmp=""
cleanup() { [ -z "$js_tmp" ] || rm -f "$js_tmp"; }
trap cleanup EXIT HUP INT TERM
sh -n "$ROOT/sb-manager-debian-alpine.sh"
echo "PASS: POSIX sh syntax"
if command -v busybox >/dev/null 2>&1; then
  busybox sh -n "$ROOT/sb-manager-debian-alpine.sh"
  echo "PASS: BusyBox ash syntax"
fi
if command -v dash >/dev/null 2>&1; then
  dash -n "$ROOT/sb-manager-debian-alpine.sh"
  echo "PASS: dash syntax"
fi
if command -v node >/dev/null 2>&1; then
  js_tmp="${TMPDIR:-/tmp}/jiedian-index-check-$$.js"
  sed -n '/^<script>$/,/^<\/script>$/p' "$ROOT/index.html" | sed '1d;$d' > "$js_tmp"
  node --check "$js_tmp"
  rm -f "$js_tmp"
  js_tmp=""
  echo "PASS: JavaScript syntax"
else
  echo "SKIP: node not installed; JavaScript syntax test skipped"
fi
sh "$ROOT/tests/test-node-export.sh"
python3 "$ROOT/tests/test_project.py"
python3 "$ROOT/tests/test_ports.py"
python3 "$ROOT/tests/test_http01.py"
python3 "$ROOT/tests/test_reload_hook.py"
python3 "$ROOT/tests/test_manual_cert.py"
python3 "$ROOT/tests/test_cf_credentials.py"
python3 "$ROOT/tests/test_acme_conf_rollback.py"
python3 "$ROOT/tests/test_acme_bootstrap.py"
python3 "$ROOT/tests/test_nat64_http01_diagnostics.py"
python3 "$ROOT/tests/test_naive.py"
python3 "$ROOT/tests/test_snell_v6.py"
python3 "$ROOT/tests/test_cron_management.py"
python3 "$ROOT/tests/test_manager_lock.py"
python3 "$ROOT/tests/test_service_manager.py"
python3 "$ROOT/tests/test_web_installer_integrity.py"
