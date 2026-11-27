#!/usr/bin/env python3
"""Exercise the generated ACME reload hook against valid and mismatched cert pairs."""
from pathlib import Path
import os
import subprocess
import tempfile
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
match = re.search(r"(?ms)^setup_reload_hook\(\) \{.*?^\}\n(?=\nstart_cron\(\))", SOURCE)
assert match, "setup_reload_hook function not found"
SETUP = match.group(0)

with tempfile.TemporaryDirectory(prefix="jiedian-reload-hook-") as td:
    base = Path(td)
    cert, key = base / "fullchain.pem", base / "privkey.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "3",
        "-subj", "/CN=cert.example.test", "-addext", "subjectAltName=DNS:cert.example.test"
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    state = base / "manager.json"
    state.write_text(
        '{"tls_domain":"cert.example.test","cert_file":' + repr(str(cert)).replace("'", '"') +
        ',"key_file":' + repr(str(key)).replace("'", '"') + '}', encoding="utf-8"
    )
    bin_dir = base / "bin"
    bin_dir.mkdir()
    log = base / "restart.log"
    rc = bin_dir / "rc-service"
    rc.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$RELOAD_TEST_LOG"\nexit 0\n', encoding="utf-8")
    rc.chmod(0o755)
    hook = base / "reload-hook"
    harness = base / "setup.sh"
    harness.write_text(
        "#!/bin/sh\nset -eu\nRELOAD_HOOK=" + repr(str(hook)) + "\n" + SETUP + "\nsetup_reload_hook\n",
        encoding="utf-8"
    )
    subprocess.run(["sh", str(harness)], check=True)
    env = os.environ.copy()
    env.update({
        "SB_MANAGER_STATE_FILE": str(state),
        "RELOAD_TEST_LOG": str(log),
        "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
    })
    subprocess.run([str(hook)], env=env, check=True)
    assert log.exists() and "sing-box restart" in log.read_text(encoding="utf-8")
    print("PASS: renewal hook restarts service when the committed certificate pair is valid")

    log.unlink()
    state.write_text(state.read_text(encoding="utf-8").replace("cert.example.test", "other.example.test"), encoding="utf-8")
    subprocess.run([str(hook)], env=env, check=True)
    assert not log.exists(), "reload hook restarted service with a domain-mismatched certificate"
    print("PASS: renewal hook skips restart when the new certificate does not match committed state")

    if log.exists():
        log.unlink()
    _, wrong_key = base / "wrong.pem", base / "wrong.key"
    subprocess.run([
        "openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(wrong_key)
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Restore the committed domain but leave the wrong private key in the state path.
    state.write_text(state.read_text(encoding="utf-8").replace("other.example.test", "cert.example.test"), encoding="utf-8")
    wrong_key.replace(key)
    subprocess.run([str(hook)], env=env, check=True)
    assert not log.exists(), "reload hook restarted service with a mismatched private key"
    print("PASS: renewal hook skips restart when certificate and private key do not match")
