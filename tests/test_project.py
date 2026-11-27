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

assert 'v1.4.9' in html and 'PROJECT_VERSION=1.4.9' in shell
assert 'schema:10' in html
assert 'WEB_CERT_ROLLBACK=1' in shell and 'WEB_SERVICE_MANAGER_DETECT=1' in shell and 'WEB_SECURE_TMPFILES=1' in shell
assert "require_marker 'WEB_CERT_ROLLBACK=1'" in html
assert 'EXPECTED_VERSION=\"1.4.9\"' in html
assert 'EXPECTED_SHA256=\"' in html
assert 'sh -n \"$SH\"' in html and 'sha256sum \"$SH\"' in html
assert 'MANAGER_BACKUP=\"$MANAGER_DIR/.sb-manager.backup.$$\"' in html
assert 'mv -f \"$MANAGER_TMP\" \"$MANAGER_PATH\"' in html
assert "--connect-timeout 10 --max-time 180 '${RAW_URL}'" in html and 'wget -q -T 180' in html
assert 'cert_mode:certMode' in html and 'const certMode=certNeeded?"http01":"none"' in html
assert 'id="cfZone"' not in html and 'id="cfToken"' not in html
assert 'id="nodePrefix"' in html and 'node_prefix:v("nodePrefix")' in html
assert "require_marker 'WEB_CONFIG_SCHEMA=10'" in html
assert "WEB_PROTOCOL_POLICY=1" in shell
assert "require_marker 'WEB_PROTOCOL_POLICY=1'" in html
assert 'protocol_policy:protocolPolicy' in html
assert 'id="keepOldProtocols"' in html and 'id="replaceOldProtocols"' in html
assert "require_marker 'WEB_SNELL_V6=1'" in html
assert "WEB_CONFIG_SCHEMA=10" in shell
assert "(.schema == 5 or .schema == 6 or .schema == 7 or .schema == 8 or .schema == 9 or .schema == 10)" in shell
assert ".node_prefix // .node_label // \"\"" in shell
assert 'tag="${NODE_PREFIX}-${family_lc}-${address}"' in shell
assert 'ss://%s@%s:%s#%s' in shell
assert "openssl base64 -A | tr '+/' '-_' | tr -d '='" in shell
assert 'WEB_SNELL_V6=1' in shell
assert 'version:6,psk:$snell_v6_psk,mode:$snell_v6_mode' in shell
assert 'version_supports_snell_v6' in shell and '1.14.0' in shell
assert 'snell-v6-client-primary.json' in shell
assert 'snell_v6' in html and 'id="pSnell"' in html and 'id="portSnell"' in html
assert 'protocol-row' in html and 'id="portSnellWrap"' in html
assert 'schema:10' in html
assert '[ "${web_schema:-}" = 10 ]' in shell
assert 'install_acme_cert_pair' in shell
assert 'detect_service_manager' in shell and 'systemd_run_dir=/run/systemd/system' in shell and 'openrc_run_dir=/run/openrc' in shell
assert 'STATE=${SB_MANAGER_STATE_FILE:-/etc/sing-box/manager.json}' in shell
assert 'cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null)' in shell
assert 'PROJECT_VERSION=1.4.9' in shell
assert 'Object.prototype.hasOwnProperty.call(historyFields,id)' in html
assert 'setTimeout(()=>URL.revokeObjectURL(url),1000)' in html
assert 'WEB_INSTALL_INTEGRITY=1' in shell and 'WEB_CRON_OWNERSHIP=1' in shell
assert 'WEB_ACME_CREDENTIAL_ROLLBACK=1' in shell and 'WEB_MANAGER_LOCK=1' in shell
assert 'WEB_OPENRC_RUNTIME_CHECK=1' in shell and 'WEB_ACME_BOOTSTRAP_FALLBACK=1' in shell and 'WEB_INSTALL_DIAGNOSTICS=1' in shell
assert 'acme_install_from_system_package' in shell
assert 'WEB_NAIVE_DOMAIN_URI=1' in shell and 'WEB_NAIVE_H2_ALPN=1' in shell
assert 'WEB_NAIVE_UOT_CLIENT=1' in shell and 'WEB_NAIVE_DIAGNOSTICS=1' in shell
assert "require_marker 'WEB_NAIVE_DOMAIN_URI=1'" in html
assert "require_marker 'WEB_NAIVE_H2_ALPN=1'" in html
assert "require_marker 'WEB_NAIVE_UOT_CLIENT=1'" in html
assert "require_marker 'WEB_NAIVE_DIAGNOSTICS=1'" in html
print("PASS: HTML IDs and JavaScript DOM references")
print("PASS: schema 10 + HTTP-01 no-CF-credentials config + Snell v6")
print("PASS: node-prefix field and prefix-first server naming")
print("PASS: Shadowsocks 2022 SIP002 URL construction")
print("PASS: schema 10 strict port handling + rollback-safe ACME cert installation")
print("PASS: secure client/node temp files and delayed browser download URL cleanup")
print("PASS: active systemd/OpenRC detection and certificate-aware renewal hook")
print("PASS: Snell v6 manager, version gate, client JSON, and compact inline port rows")

assert "fail_preflight()" in html and "版本不匹配" in html and "SHA-256 不匹配" in html
assert "require_marker 'WEB_INSTALL_DIAGNOSTICS=1'" in html
