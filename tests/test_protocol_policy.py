#!/usr/bin/env python3
"""Regression tests for preserve-vs-replace existing protocol policy."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HTML = (ROOT / "index.html").read_text(encoding="utf-8")
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

assert 'id="keepOldProtocols"' in HTML
assert 'id="replaceOldProtocols"' in HTML
assert 'let protocolPolicy="preserve"' in HTML
assert 'schema:11,protocol_policy:protocolPolicy' in HTML
assert "WEB_PROTOCOL_POLICY=1" in SOURCE
assert "manual) CERT_MODE=manual" in SOURCE
assert '.protocol_policy == "preserve" or .protocol_policy == "replace"' in SOURCE
assert '保留以前的协议' in HTML and '不保留以前的协议' in HTML

start = SOURCE.index("apply_web_protocol_policy() {")
end = SOURCE.index("\n}\n\nrestore_web_file()", start) + 2
FUNCTION = SOURCE[start:end]

def run_policy(policy, requested, tls_domain="", reality_sni=""):
    with tempfile.TemporaryDirectory(prefix="jiedian-protocol-policy-") as td:
        harness = Path(td) / "policy.sh"
        variables = f'''#!/bin/sh
set -eu
err() {{ printf '%s\\n' "$*" >&2; exit 1; }}
web_protocol_sync=1
web_protocol_policy="{policy}"
web_old_enable_anytls=1
web_old_enable_ws=0
web_old_enable_argo=1
web_old_enable_ss2022=1
web_old_enable_reality=1
web_old_enable_naive=0
web_old_enable_anyreality=0
web_old_enable_snell_v6=1
web_old_origin_addr="198.51.100.10"
web_old_origin_ipv6="2001:db8::10"
web_old_tls_domain="old.example.com"
web_old_cert_mode="standalone"
web_old_cf_zone_name="example.com"
web_old_cf_token="old-cf-token"
web_old_cf_zone_id="0123456789abcdef0123456789abcdef"
web_old_argo_host="argo.example.com"
web_old_argo_server="argo.example.com"
web_old_argo_tunnel_name="old tunnel"
web_old_argo_token="old-argo-token"
web_old_reality_sni="old-reality.example.com"
web_old_snell_v6_mode="unshaped"
web_old_node_prefix="OLD"
ENABLE_ANYTLS={requested.get("anytls",0)}
ENABLE_WS_TLS={requested.get("ws",0)}
ENABLE_WS_ARGO={requested.get("argo",0)}
ENABLE_SS2022={requested.get("ss2022",0)}
ENABLE_VLESS_REALITY={requested.get("reality",0)}
ENABLE_NAIVE={requested.get("naive",0)}
ENABLE_ANYTLS_REALITY={requested.get("anyreality",0)}
ENABLE_SNELL_V6={requested.get("snell",0)}
ORIGIN_ADDR=""
ORIGIN_IPV6=""
TLS_DOMAIN={json.dumps(tls_domain)}
REALITY_SNI={json.dumps(reality_sni)}
cert_mode="none"
CF_ZONE_NAME=""
cf_token=""
zone_id=""
ARGO_HOST=""
ARGO_SERVER=""
ARGO_TUNNEL_NAME=""
ARGO_TOKEN=""
SNELL_V6_MODE="default"
NODE_PREFIX=""
'''
        harness.write_text(variables + FUNCTION + '''
apply_web_protocol_policy
printf '%s\\n' "$ENABLE_ANYTLS|$ENABLE_WS_TLS|$ENABLE_WS_ARGO|$ENABLE_SS2022|$ENABLE_VLESS_REALITY|$ENABLE_NAIVE|$ENABLE_ANYTLS_REALITY|$ENABLE_SNELL_V6"
printf '%s\\n' "$TLS_DOMAIN|$cert_mode|$CF_ZONE_NAME|$cf_token|$zone_id"
printf '%s\\n' "$ARGO_HOST|$ARGO_SERVER|$ARGO_TUNNEL_NAME|$ARGO_TOKEN"
printf '%s\\n' "$REALITY_SNI|$SNELL_V6_MODE|$ORIGIN_ADDR|$ORIGIN_IPV6|$NODE_PREFIX"
''', encoding="utf-8")
        return subprocess.run(["sh", str(harness)], text=True, capture_output=True)

all_off = {"anytls":0,"ws":0,"argo":0,"ss2022":0,"reality":0,"naive":0,"anyreality":0,"snell":0}
preserved = run_policy("preserve", all_off)
assert preserved.returncode == 0, preserved.stderr
lines = preserved.stdout.splitlines()
assert lines[0] == "1|0|1|1|1|0|0|1", lines[0]
assert lines[1] == "old.example.com|http01|example.com|old-cf-token|0123456789abcdef0123456789abcdef", lines[1]
assert lines[2] == "argo.example.com|argo.example.com|old tunnel|old-argo-token", lines[2]
assert lines[3] == "old-reality.example.com|unshaped|198.51.100.10|2001:db8::10|OLD", lines[3]

replaced = run_policy("replace", all_off)
assert replaced.returncode == 0, replaced.stderr
assert replaced.stdout.splitlines()[0] == "0|0|0|0|0|0|0|0"

bad_tls = run_policy("preserve", all_off, tls_domain="new.example.com")
assert bad_tls.returncode != 0
assert "共用原证书域名" in bad_tls.stderr

bad_reality = run_policy("preserve", all_off, reality_sni="new-reality.example.com")
assert bad_reality.returncode != 0
assert "共享 SNI" in bad_reality.stderr

print("PASS: preserve mode unions old protocols and restores shared credentials/settings")
print("PASS: replace mode leaves the requested protocol set unchanged")
print("PASS: unsafe shared TLS-domain and Reality-SNI changes are rejected")
