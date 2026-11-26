#!/usr/bin/env python3
"""Test staged manual certificate replacement and rollback behavior."""
from pathlib import Path
import os
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}()", start) + 2
    return SOURCE[start:end]

CHECK = extract("check_cert_pair", "install_acme_cert_pair")
INSTALL = extract("install_manual_cert", "cloudflared_supports_token_file")

def make_cert(base: Path, domain: str, name: str):
    cert, key = base / f"{name}.pem", base / f"{name}.key"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "3",
        "-subj", f"/CN={domain}", "-addext", f"subjectAltName=DNS:{domain}"
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cert, key

def run_case(fail_move=False, mismatch=False):
    with tempfile.TemporaryDirectory(prefix="jiedian-manual-cert-") as td:
        base = Path(td)
        out = base / "cert-dir"
        out.mkdir()
        old_cert, old_key = make_cert(base, "cert.example.test", "old")
        new_cert, new_key = make_cert(base, "cert.example.test", "new")
        if mismatch:
            _, wrong_key = make_cert(base, "other.example.test", "wrong")
            new_key = wrong_key
        (out / "fullchain.pem").write_bytes(old_cert.read_bytes())
        (out / "privkey.pem").write_bytes(old_key.read_bytes())
        old_pair = ((out / "fullchain.pem").read_bytes(), (out / "privkey.pem").read_bytes())
        harness = base / "test.sh"
        mv_stub = '''mv() {
  [ "$1" != -f ] || shift
  case "$1" in */privkey.pem) return 1 ;; esac
  command mv "$@"
}
''' if fail_move else ""
        harness.write_text(f'''#!/bin/sh
set -eu
CERT_DIR={str(out)!r}
CERT_FILE={str(out / 'fullchain.pem')!r}
KEY_FILE={str(out / 'privkey.pem')!r}
CERT_MODE=none
SRC_CERT={str(new_cert)!r}
SRC_KEY={str(new_key)!r}
ask_count=0
ask_value() {{ ask_count=$((ask_count + 1)); if [ "$ask_count" -eq 1 ]; then REPLY=$SRC_CERT; else REPLY=$SRC_KEY; fi; }}
warn() {{ printf '[WARN] %s\\n' "$*" >&2; }}
err() {{ printf '[ERR] %s\\n' "$*" >&2; exit 1; }}
chown() {{ return 0; }}
{mv_stub}
{CHECK}
{INSTALL}
install_manual_cert cert.example.test
''', encoding="utf-8")
        proc = subprocess.run(["sh", str(harness)], text=True, capture_output=True)
        final_pair = ((out / "fullchain.pem").read_bytes(), (out / "privkey.pem").read_bytes())
        return proc, final_pair == old_pair, final_pair, new_cert.read_bytes(), new_key.read_bytes()

p, restored, final_pair, new_cert_bytes, new_key_bytes = run_case()
assert p.returncode == 0, p.stdout + p.stderr
assert final_pair == (new_cert_bytes, new_key_bytes)
assert not restored
print("PASS: valid manual certificate pair replaces old pair after staging and validation")

p, restored, *_ = run_case(mismatch=True)
assert p.returncode != 0 and restored, p.stdout + p.stderr
print("PASS: mismatched manual certificate/key is rejected without changing live pair")

p, restored, *_ = run_case(fail_move=True)
assert p.returncode != 0 and restored, p.stdout + p.stderr
print("PASS: partial manual certificate replacement restores the previous pair")
