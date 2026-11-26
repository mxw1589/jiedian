#!/usr/bin/env python3
"""Verify Cloudflare token/Zone ID files are atomically written with owner-only mode."""
from pathlib import Path
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}()", start) + 2
    return SOURCE[start:end]

WRITE = extract("write_cf_credentials_for_add", "prepare_add_certificate")
with tempfile.TemporaryDirectory(prefix="jiedian-cf-credentials-") as td:
    base = Path(td)
    token, zone = base / "cloudflare.token", base / "zone-id"
    harness = base / "test.sh"
    common = f'''#!/bin/sh
set -eu
CF_TOKEN_FILE={str(token)!r}
CF_ZONE_ID_FILE={str(zone)!r}
chown() {{ return 0; }}
{WRITE}
'''
    harness.write_text(common + 'write_cf_credentials_for_add "token-secret-value" "0123456789abcdef0123456789abcdef"\n', encoding="utf-8")
    subprocess.run(["sh", str(harness)], check=True)
    assert token.read_text(encoding="utf-8") == "token-secret-value"
    assert zone.read_text(encoding="utf-8") == "0123456789abcdef0123456789abcdef"
    assert stat.S_IMODE(token.stat().st_mode) == 0o600
    assert stat.S_IMODE(zone.stat().st_mode) == 0o600
    assert not list(base.glob("*.tmp.*"))

    harness.write_text(common + 'write_cf_credentials_for_add "" ""\n', encoding="utf-8")
    subprocess.run(["sh", str(harness)], check=True)
    assert token.read_text(encoding="utf-8") == "token-secret-value"
    assert not zone.exists()
    assert not list(base.glob("*.tmp.*"))
print("PASS: Cloudflare token/Zone ID use 0600 atomic writes; clearing Zone ID leaves token intact")
