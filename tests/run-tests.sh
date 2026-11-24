#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sh -n "$ROOT/sb-manager-debian-alpine.sh"
echo "PASS: POSIX sh syntax"
if command -v dash >/dev/null 2>&1; then
  dash -n "$ROOT/sb-manager-debian-alpine.sh"
  echo "PASS: dash syntax"
fi
if command -v node >/dev/null 2>&1; then
  sed -n '/^<script>$/,/^<\/script>$/p' "$ROOT/index.html" | sed '1d;$d' > "${TMPDIR:-/tmp}/jiedian-index-check-$$.js"
  node --check "${TMPDIR:-/tmp}/jiedian-index-check-$$.js"
  rm -f "${TMPDIR:-/tmp}/jiedian-index-check-$$.js"
  echo "PASS: JavaScript syntax"
else
  echo "SKIP: node not installed; JavaScript syntax test skipped"
fi
sh "$ROOT/tests/test-node-export.sh"
python3 "$ROOT/tests/test_project.py"
