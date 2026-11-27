#!/usr/bin/env python3
"""Snell v6 server/client profile and minimum-core regression tests."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
assert "# WEB_SNELL_V6=1" in SOURCE
assert 'version:6,psk:$snell_v6_psk,mode:$snell_v6_mode' in SOURCE
assert 'enabled_snell_v6' in SOURCE and 'snell_v6_port' in SOURCE

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}()", start) + 2
    return SOURCE[start:end]

VERSION_FN = extract("version_supports_snell_v6", "version_supports_required_features")
with tempfile.TemporaryDirectory(prefix="jiedian-snell-version-") as td:
    script = Path(td) / "versions.sh"
    script.write_text("#!/bin/sh\n" + VERSION_FN + "\n"
                      "version_supports_snell_v6 1.13.9 && exit 11 || :\n"
                      "version_supports_snell_v6 1.14.0 || exit 12\n"
                      "version_supports_snell_v6 1.14.7 || exit 13\n"
                      "version_supports_snell_v6 1.15.0 || exit 14\n", encoding="utf-8")
    subprocess.run(["sh", str(script)], check=True)
print("PASS: Snell v6 requires sing-box 1.14.0 or newer")

PROFILE_FN = extract("write_snell_v6_client_profile", "write_snell_v6_client_json")
with tempfile.TemporaryDirectory(prefix="jiedian-snell-profile-") as td:
    root = Path(td)
    app = root / "app"
    app.mkdir()
    script = root / "profiles.sh"
    script.write_text(
        "#!/bin/sh\nset -eu\n"
        "chown() { return 0; }\n"
        f'APP_DIR="{app}"\n'
        'SNELL_V6_PORT=23456\n'
        'SNELL_V6_PSK=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
        'SNELL_V6_MODE=default\n'
        + PROFILE_FN + "\n"
        + 'write_snell_v6_client_profile "$APP_DIR/snell-client.json" "2001:db8::1234"\n',
        encoding="utf-8",
    )
    subprocess.run(["sh", str(script)], check=True)
    profile_path = app / "snell-client.json"
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    outbound = next(x for x in profile["outbounds"] if x["type"] == "snell")
    assert outbound["server"] == "2001:db8::1234"
    assert outbound["server_port"] == 23456
    assert outbound["version"] == 6
    assert outbound["mode"] == "default"
    assert len(outbound["psk"]) == 64
    assert profile["route"]["final"] == "snell-v6"
    assert (profile_path.stat().st_mode & 0o777) == 0o600
print("PASS: Snell v6 sing-box client JSON generation, IPv6 server address, PSK, mode and 0600 permissions")


# Exercise the actual build_config function with stubs for service/system side effects.
BUILD_FN = extract("build_config", "node_tag")
with tempfile.TemporaryDirectory(prefix="jiedian-snell-server-config-") as td:
    root = Path(td)
    config_path = root / "config.json"
    state_path = root / "manager.json"
    core_stub = root / "sing-box-stub"
    core_stub.write_text("#!/bin/sh\n[ \"$1\" = check ] && exit 0\nexit 1\n", encoding="utf-8")
    core_stub.chmod(0o755)
    harness = root / "build-config.sh"
    vars_text = f'''#!/bin/sh
set -eu
chown() {{ return 0; }}
service_restart() {{ return 0; }}
save_state() {{ return 0; }}
msg() {{ :; }}
warn() {{ printf "%s\\n" "$*" >&2; }}
err() {{ printf "%s\\n" "$*" >&2; exit 1; }}
ipv6_kernel_enabled() {{ return 0; }}
CONFIG_FILE="{config_path}"
STATE_FILE="{state_path}"
SB_BIN="{core_stub}"
ENABLE_ANYTLS=0
ENABLE_WS_TLS=0
ENABLE_WS_ARGO=0
ENABLE_SS2022=0
ENABLE_VLESS_REALITY=0
ENABLE_NAIVE=0
ENABLE_ANYTLS_REALITY=0
ENABLE_SNELL_V6=1
SS2022_PORT=""
SS2022_METHOD="2022-blake3-aes-128-gcm"
SS2022_PASSWORD=""
SNELL_V6_PORT="23456"
SNELL_V6_PSK="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SNELL_V6_MODE="default"
ARGO_PORT=""
ARGO_UUID=""
ARGO_PATH=""
TLS_DOMAIN=""
REALITY_SNI=""
CERT_FILE=""
KEY_FILE=""
ANYTLS_PASSWORD=""
WS_UUID=""
REALITY_UUID=""
REALITY_PRIVATE=""
REALITY_SID=""
WS_PATH=""
ANYTLS_PORT=""
WS_PORT=""
REALITY_PORT=""
NAIVE_PORT=""
NAIVE_USERNAME=""
NAIVE_PASSWORD=""
ANYREALITY_PORT=""
ANYREALITY_PASSWORD=""
ANYREALITY_PRIVATE=""
ANYREALITY_SID=""
'''
    harness.write_text(vars_text + BUILD_FN + "\nbuild_config\n", encoding="utf-8")
    subprocess.run(["sh", str(harness)], check=True)
    generated = json.loads(config_path.read_text(encoding="utf-8"))
    inbound = next(x for x in generated["inbounds"] if x["type"] == "snell")
    assert inbound["listen"] == "::"
    assert inbound["listen_port"] == 23456
    assert inbound["version"] == 6
    assert inbound["psk"].startswith("0123456789abcdef")
    assert inbound["mode"] == "default"
print("PASS: actual manager build_config emits valid Snell v6 inbound fields")


# Validate Snell state migration and required credentials through the real validator.
STATE_FN = extract("manager_state_is_valid", "capture_web_state")
with tempfile.TemporaryDirectory(prefix="jiedian-snell-state-") as td:
    state_path = Path(td) / "manager.json"
    base_state = {
        "enabled_anytls": False, "enabled_ws_tls": False, "enabled_ws_argo": False,
        "enabled_ss2022": False, "enabled_vless_reality": False, "enabled_naive": False,
        "enabled_anytls_reality": False, "enabled_snell_v6": True,
        "snell_v6_psk": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "snell_v6_port": 23456, "snell_v6_mode": "default", "origin_ipv6": "2001:db8::1234"
    }
    harness = Path(td) / "state-check.sh"
    harness.write_text("#!/bin/sh\nSTATE_FILE=\"" + str(state_path) + "\"\n" + STATE_FN + "\nmanager_state_is_valid\n", encoding="utf-8")
    state_path.write_text(json.dumps(base_state), encoding="utf-8")
    subprocess.run(["sh", str(harness)], check=True)
    bad_state = dict(base_state, snell_v6_psk="short")
    state_path.write_text(json.dumps(bad_state), encoding="utf-8")
    assert subprocess.run(["sh", str(harness)]).returncode != 0
    bad_mode = dict(base_state, snell_v6_mode="unsafe-raw")
    state_path.write_text(json.dumps(bad_mode), encoding="utf-8")
    assert subprocess.run(["sh", str(harness)]).returncode != 0
print("PASS: real manager state validator accepts valid Snell v6 state and rejects short PSK / unsafe mode")

assert '"schema == 9"' not in SOURCE  # keep this test focused on emitted protocol config.
print("PASS: Snell v6 source invariants")
