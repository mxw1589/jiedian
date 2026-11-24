#!/usr/bin/env python3
from pathlib import Path
import re, collections, subprocess, sys

root = Path(__file__).resolve().parents[1]
html = (root / "index.html").read_text(encoding="utf-8")
shell = (root / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

class Parser(__import__("html.parser", fromlist=["HTMLParser"]).HTMLParser):
    def __init__(self):
        super().__init__(); self.ids=[]
    def handle_starttag(self, tag, attrs):
        d=dict(attrs)
        if "id" in d: self.ids.append(d["id"])

p=Parser(); p.feed(html)
duplicates=[x for x,c in collections.Counter(p.ids).items() if c>1]
assert not duplicates, f"duplicate HTML ids: {duplicates}"
ids=set(p.ids)
js=re.search(r"<script>(.*?)</script>", html, re.S)
assert js, "inline JS missing"
for ref in set(re.findall(r'\$\("([^"]+)"\)', js.group(1))):
    assert ref in ids, f"JS references missing DOM id: {ref}"
ids_arr=re.search(r"const ids=\[(.*?)\];", js.group(1), re.S)
assert ids_arr
for ref in re.findall(r'"([^"]+)"', ids_arr.group(1)):
    assert ref in ids, f"event binding references missing DOM id: {ref}"

assert 'schema:8' in html
assert 'cert_mode:certMode' in html and 'const certMode=certNeeded?"http01":"none"' in html
assert 'id="cfZone"' not in html and 'id="cfToken"' not in html
assert 'id="nodePrefix"' in html and 'node_prefix:v("nodePrefix")' in html
assert 'grep -q \'WEB_CONFIG_SCHEMA=8\'' in html
assert "WEB_CONFIG_SCHEMA=8" in shell
assert "(.schema == 5 or .schema == 6 or .schema == 7 or .schema == 8)" in shell
assert ".node_prefix // .node_label // \"\"" in shell
assert 'tag="${NODE_PREFIX}-${family_lc}-${address}"' in shell
assert 'ss://%s@%s:%s#%s' in shell
assert "openssl base64 -A | tr '+/' '-_' | tr -d '='" in shell
assert "snell" not in shell.lower(), "Snell code appeared unexpectedly; audit assumptions changed"
print("PASS: HTML IDs and JavaScript DOM references")
print("PASS: schema 8 + HTTP-01 no-CF-credentials config")
print("PASS: node-prefix field and prefix-first server naming")
print("PASS: Shadowsocks 2022 SIP002 URL construction")
print("NOTE: Snell is absent from supplied Shell source; no fake Snell node is emitted")
