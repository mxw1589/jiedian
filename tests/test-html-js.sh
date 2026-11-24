#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT HUP INT TERM
python3 - "$ROOT/index.html" "$TMPDIR/index-inline.js" "$TMPDIR/direct-install.sh" <<'PYCODE'
import re,sys
html=open(sys.argv[1],encoding='utf-8').read()
scripts=re.findall(r'<script>(.*?)</script>',html,re.S)
assert len(scripts)==1, f'expected one inline UI script, got {len(scripts)}'
open(sys.argv[2],'w',encoding='utf-8').write(scripts[0])
direct=re.search(r'<pre id="directInstallText"[^>]*>([\s\S]*?)</pre>',html)
assert direct, 'direct install shell command is present'
open(sys.argv[3],'w',encoding='utf-8').write(direct.group(1))
assert 'v1.0.9; selectable IPv4, IPv6 or dual-stack node display from web-generated commands' in direct.group(1), 'direct install must enforce manager script version'
assert 'raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh' in html
assert 'github.com/mxw1589/jiedian/blob/main/sb-manager-debian-alpine.sh' in html
PYCODE
node --check "$TMPDIR/index-inline.js"
sh -n "$TMPDIR/direct-install.sh"
node "$ROOT/tests/test-manager-ui-smoke.js"
echo 'PASS: primary index page JavaScript and direct SSH installer shell syntax are valid.'
