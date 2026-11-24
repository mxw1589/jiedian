#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
TMP="$TMPDIR/inline.js"
MANAGER_TMP="$TMPDIR/manager-inline.js"
DIRECT_TMP="$TMPDIR/direct-install.sh"
trap 'rm -rf "$TMPDIR"' EXIT HUP INT TERM
python3 - "$ROOT/index.html" "$TMP" "$ROOT/manager.html" "$MANAGER_TMP" "$DIRECT_TMP" <<'PY'
import re,sys
html=open(sys.argv[1],encoding='utf-8').read()
scripts=re.findall(r'<script>(.*?)</script>',html,re.S)
assert len(scripts)==1, f'expected one inline UI script, got {len(scripts)}'
open(sys.argv[2],'w',encoding='utf-8').write(scripts[0])
manager=open(sys.argv[3],encoding='utf-8').read()
manager_scripts=re.findall(r'<script>(.*?)</script>',manager,re.S)
assert len(manager_scripts)==1, f'expected one manager inline script, got {len(manager_scripts)}'
open(sys.argv[4],'w',encoding='utf-8').write(manager_scripts[0])
direct=re.search(r'<pre id="directInstallText"[^>]*>([\s\S]*?)</pre>',manager)
assert direct, 'direct install shell command is present'
open(sys.argv[5],'w',encoding='utf-8').write(direct.group(1))
assert 'v1.0.8; compact IPv4/IPv6 node lists and per-family client configs' in direct.group(1), 'direct install must enforce manager script version'
PY
node --check "$TMP"
node --check "$MANAGER_TMP"
node --check "$ROOT/generator.js"
sh -n "$DIRECT_TMP"
node "$ROOT/tests/test-generator.js"
node "$ROOT/tests/test-ui-smoke.js"
node "$ROOT/tests/test-manager-ui-smoke.js"
echo 'PASS: both HTML pages, generator JavaScript and UI smoke tests pass.'
