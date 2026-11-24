#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
TMP="$TMPDIR/inline.js"
trap 'rm -rf "$TMPDIR"' EXIT HUP INT TERM
python3 - "$ROOT/index.html" "$TMP" <<'PY'
import re,sys
html=open(sys.argv[1],encoding='utf-8').read()
scripts=re.findall(r'<script>(.*?)</script>',html,re.S)
assert len(scripts)==1, f'expected one inline UI script, got {len(scripts)}'
open(sys.argv[2],'w',encoding='utf-8').write(scripts[0])
PY
node --check "$TMP"
node --check "$ROOT/generator.js"
node "$ROOT/tests/test-generator.js"
node "$ROOT/tests/test-ui-smoke.js"
echo 'PASS: HTML inline JavaScript and generator JavaScript parse successfully.'
