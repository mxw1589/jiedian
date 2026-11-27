#!/usr/bin/env python3
"""Regression tests for NaiveProxy links, client profiles, TLS and diagnostics."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

assert '# PROJECT_VERSION=1.4.7' in SOURCE
assert 'server_name:$tls_domain,alpn:["h2"],certificate_path:$cert_file,key_path:$key_file' in SOURCE
assert 'naive+https://${naive_user_uri}:${naive_password_uri}@${TLS_DOMAIN}:${NAIVE_PORT}/#${tag_uri}' in SOURCE
assert 'naive_user_uri=$(jq -nr --arg value "$NAIVE_USERNAME" \'$value | @uri\')' in SOURCE
assert 'naive_password_uri=$(jq -nr --arg value "$NAIVE_PASSWORD" \'$value | @uri\')' in SOURCE
assert 'naive+https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${origin_uri}:${NAIVE_PORT}/?sni=${TLS_DOMAIN}' not in SOURCE
assert 'naive+https://${NAIVE_USERNAME}:${NAIVE_PASSWORD}@${origin6_uri}:${NAIVE_PORT}/?sni=${TLS_DOMAIN}' not in SOURCE
assert 'udp_over_tcp:{enabled:true,version:2}' in SOURCE
assert 'quic:false' in SOURCE
assert 'naive-client-uot.json' in SOURCE
assert 'openssl x509 -in "$CERT_FILE" -noout -checkhost "$TLS_DOMAIN"' in SOURCE
assert 'openssl x509 -in "$CERT_FILE" -noout -checkend 604800' in SOURCE
assert 'openssl pkey -in "$KEY_FILE" -pubout' in SOURCE
assert 'ALPN protocol: h2' in SOURCE
assert 'getent ahostsv6 "$TLS_DOMAIN"' in SOURCE

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}()", start) + 2
    return SOURCE[start:end]

PROFILE = extract("write_naive_client_profile", "write_naive_client_json")

with tempfile.TemporaryDirectory(prefix="jiedian-naive-test-") as td:
    root = Path(td)
    app_dir = root / "app"
    app_dir.mkdir()
    harness = root / "naive-profiles.sh"
    harness.write_text(
        "set -eu\n"
        "chown() { return 0; }\n"
        f'APP_DIR="{app_dir}"\n'
        'TLS_DOMAIN="proxy.example.test"\n'
        'NAIVE_PORT="18443"\n'
        'NAIVE_USERNAME="naive-user"\n'
        'NAIVE_PASSWORD="safe-password-123"\n'
        + PROFILE
        + '\nwrite_naive_client_profile "$APP_DIR/naive-client.json" false\n'
        + 'write_naive_client_profile "$APP_DIR/naive-client-uot.json" true\n',
        encoding="utf-8",
    )
    subprocess.run(["sh", str(harness)], check=True)

    tcp_path = app_dir / "naive-client.json"
    uot_path = app_dir / "naive-client-uot.json"
    tcp = json.loads(tcp_path.read_text())
    uot = json.loads(uot_path.read_text())

    for config in (tcp, uot):
        outbound = next(x for x in config["outbounds"] if x["type"] == "naive")
        assert outbound["server"] == "proxy.example.test"
        assert outbound["server_port"] == 18443
        assert outbound["tls"]["enabled"] is True
        assert outbound["tls"]["server_name"] == "proxy.example.test"
        assert config["route"]["final"] == "naive-proxy"
        assert config["inbounds"][0]["listen"] == "127.0.0.1"

    tcp_out = next(x for x in tcp["outbounds"] if x["type"] == "naive")
    uot_out = next(x for x in uot["outbounds"] if x["type"] == "naive")
    assert "udp_over_tcp" not in tcp_out
    assert uot_out["udp_over_tcp"] == {"enabled": True, "version": 2}
    assert (tcp_path.stat().st_mode & 0o777) == 0o600
    assert (uot_path.stat().st_mode & 0o777) == 0o600

print("PASS: Naive URI uses certificate domain, server TLS uses h2, TCP/UoT client JSON profiles are valid and private")
