#!/usr/bin/env python3
from pathlib import Path
import json
import subprocess
import tempfile
import shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
HTML = (ROOT / "index.html").read_text(encoding="utf-8")

assert "# WEB_NODE_IP_MODE=1" in SOURCE
assert "# WEB_CONFIG_SCHEMA=11" in SOURCE
assert 'schema:11,protocol_policy:protocolPolicy,node_ip_mode:nodeIpMode' in HTML
assert 'let nodeIpMode="dual"' in HTML
assert all(f'id="{x}"' in HTML for x in ("nodeIpDual", "nodeIpV4", "nodeIpV6"))
assert 'node_ip_mode:$node_ip_mode' in SOURCE
assert 'node_ip_mode == "dual"' in SOURCE
assert 'node_ip_mode == "ipv4"' in SOURCE
assert 'node_ip_mode == "ipv6"' in SOURCE
assert "PSK：%s\\n'" in SOURCE
assert any(line.endswith(" " + chr(92)) and not line.endswith(chr(92) * 2) for line in SOURCE.splitlines() if "Snell v6 %s | 地址" in line)

def extract(name, next_name=None):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index("\n}\n", start) + 2
    return SOURCE[start:end]

# Explicit IP literals are filtered; DNS names remain domain endpoints.
HELPERS = "\n".join([
    extract("valid_ipv4_address", "valid_ipv6_literal"),
    extract("node_ip_mode_label", "node_mode_allows_ipv4"),
    extract("node_mode_allows_ipv4", "node_mode_allows_ipv6"),
    extract("node_mode_allows_ipv6", "node_address_allowed"),
    extract("node_address_allowed", "show_nodes"),
])
filter_body = "\n".join([
    "check() {",
    '  NODE_IP_MODE=$1; address=$2; expected=$3',
    '  if node_address_allowed "$address"; then actual=yes; else actual=no; fi',
    '  [ "$actual" = "$expected" ] || { echo "$NODE_IP_MODE $address expected $expected got $actual" >&2; exit 1; }',
    "}",
    'NODE_IP_MODE=dual',
    '[ "$(node_ip_mode_label)" = "IPv4 + IPv6 双栈" ]',
    'check dual 198.51.100.10 yes',
    'check dual 2001:db8::10 yes',
    'check dual proxy.example.test yes',
    'check dual "" no',
    'check ipv4 198.51.100.10 yes',
    'check ipv4 2001:db8::10 no',
    'check ipv4 proxy.example.test yes',
    'check ipv6 198.51.100.10 no',
    'check ipv6 2001:db8::10 yes',
    'check ipv6 proxy.example.test yes',
])
with tempfile.TemporaryDirectory(prefix="jiedian-node-family-filter-") as td:
    harness = Path(td) / "filter.sh"
    harness.write_text("#!/bin/sh\nset -eu\n" + HELPERS + "\n" + filter_body + "\n", encoding="utf-8")
    subprocess.run(["sh", str(harness)], check=True)
print("PASS: explicit IPv4 / IPv6 node filtering; domain endpoints remain domain names")

# Verify required address families and independent auto-detection.
RESOLVE = extract("resolve_install_addresses", "resolve_install_domains")
base_lines = [
    "#!/bin/sh", "set -eu",
    "err() { printf '%s\\n' \"$*\" >&2; exit 1; }",
    "warn() { :; }", "msg() { :; }",
    'valid_ipv4_address() { [ "$1" = "198.51.100.10" ]; }',
    'valid_main_address() { [ -n "$1" ] && case "$1" in *:*) return 1;; esac; }',
    'valid_ipv6_address() { [ "$1" = "2001:db8::10" ]; }',
    "ipv6_kernel_enabled() { return 0; }",
    'detect_public_ip() { case "$1" in 4) printf "%s" "${DETECT_V4:-}" ;; 6) printf "%s" "${DETECT_V6:-}" ;; esac; }',
]
base = "\n".join(base_lines) + "\n"
with tempfile.TemporaryDirectory(prefix="jiedian-node-family-validation-") as td:
    harness = Path(td) / "resolve.sh"
    def run_resolve(mode, v4="", v6="", detect4="", detect6=""):
        vars_text = "\n".join([
            "NEED_ORIGIN=1", f'NODE_IP_MODE="{mode}"',
            f'ORIGIN_ADDR="{v4}"', f'ORIGIN_IPV6="{v6}"',
            "ENABLE_ANYTLS=1", "ENABLE_VLESS_REALITY=0",
            "ENABLE_ANYTLS_REALITY=0", "ENABLE_SS2022=0",
            "ENABLE_SNELL_V6=0", "ENABLE_WS_TLS=0", "ENABLE_WS_ARGO=0",
            'WS_SERVER=""', 'ARGO_SERVER=""',
            f'DETECT_V4="{detect4}"', f'DETECT_V6="{detect6}"',
        ])
        harness.write_text(base + vars_text + "\n" + RESOLVE + "\nresolve_install_addresses\n", encoding="utf-8")
        return subprocess.run(["sh", str(harness)], text=True, capture_output=True)
    result = run_resolve("dual", "198.51.100.10", "2001:db8::10")
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert run_resolve("ipv4", "198.51.100.10", "").returncode == 0
    assert run_resolve("ipv6", "", "2001:db8::10").returncode == 0
    assert run_resolve("dual", "198.51.100.10", "").returncode != 0
    assert run_resolve("ipv4", "", "2001:db8::10").returncode != 0
    assert run_resolve("ipv6", "198.51.100.10", "").returncode != 0
    auto = run_resolve("dual", "", "", "198.51.100.10", "2001:db8::10")
    assert auto.returncode == 0, auto.stderr
print("PASS: dual / IPv4-only / IPv6-only address validation and independent detection")

def profile_functions(kind):
    if kind == "snell":
        return (
            extract("write_snell_v6_client_profile", "write_snell_v6_client_json"),
            extract("write_snell_v6_client_json", "show_ss2022_node"),
            "snell-v6-client-primary.json", "snell-v6-client-ipv6.json", "snell",
            ["ENABLE_SNELL_V6=1", "SNELL_V6_PORT=23456",
             "SNELL_V6_PSK=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
             "SNELL_V6_MODE=default"],
            "write_snell_v6_client_json"
        )
    return (
        extract("write_anyreality_client_profile", "write_anyreality_client_json"),
        extract("write_anyreality_client_json", "write_naive_client_profile"),
        "anytls-reality-client.json", "anytls-reality-client-ipv6.json", "anytls",
        ["ENABLE_ANYTLS_REALITY=1", "ANYREALITY_PORT=23457",
         'ANYREALITY_PASSWORD="secret-password"', 'REALITY_SNI="www.example.test"',
         'ANYREALITY_PUBLIC="public-key"', 'ANYREALITY_SID="abcd1234"'],
        "write_anyreality_client_json"
    )

def run_profile_writer(kind, mode):
    profile_fn, writer_fn, primary_name, secondary_name, out_type, extra, call = profile_functions(kind)
    with tempfile.TemporaryDirectory(prefix="jiedian-node-family-profile-") as td:
        app = Path(td) / "app"
        app.mkdir()
        vars_lines = [
            "#!/bin/sh", "set -eu", "chown() { return 0; }",
            f'APP_DIR="{app}"', f'NODE_IP_MODE="{mode}"',
            'ORIGIN_ADDR="198.51.100.10"', 'ORIGIN_IPV6="2001:db8::10"',
        ] + extra
        script = Path(td) / "writer.sh"
        script.write_text("\n".join(vars_lines) + "\n" + profile_fn + "\n" + writer_fn + "\n" + call + "\n", encoding="utf-8")
        subprocess.run(["sh", str(script)], check=True)
        primary_path = app / primary_name
        primary = json.loads(primary_path.read_text())
        outbound = primary if kind == "anyreality" else next(x for x in primary["outbounds"] if x["type"] == out_type)
        expected = "2001:db8::10" if mode == "ipv6" else "198.51.100.10"
        assert outbound["server"] == expected, (kind, mode, outbound["server"])
        secondary_path = app / secondary_name
        if mode == "dual":
            assert secondary_path.exists()
            secondary = json.loads(secondary_path.read_text())
            secondary_out = secondary if kind == "anyreality" else next(x for x in secondary["outbounds"] if x["type"] == out_type)
            assert secondary_out["server"] == "2001:db8::10"
        else:
            assert not secondary_path.exists()
        assert primary_path.stat().st_mode & 0o777 == 0o600

if shutil.which("jq"):
    for mode in ("dual", "ipv4", "ipv6"):
        run_profile_writer("snell", mode)
    print("PASS: Snell v6 client JSON follows selected family")
    for mode in ("dual", "ipv4", "ipv6"):
        run_profile_writer("anyreality", mode)
    print("PASS: AnyTLS + Reality client JSON follows selected family")
else:
    print("SKIP: jq unavailable; client JSON profile tests skipped")
