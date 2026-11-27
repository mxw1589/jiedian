#!/usr/bin/env python3
"""Behavioral tests for HTTP-01 certificate reuse on acme.sh exit status 2."""
from pathlib import Path
import os, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}()", start) + 2
    return SOURCE[start:end]

HINT = extract("http01_failure_hint", "run_http01_issue_logged")
LOGGED = extract("run_http01_issue_logged", "issue_http_cert")
ISSUE = extract("issue_http_cert", "check_cert_pair")
CHECK = extract("check_cert_pair", "install_acme_cert_pair")
INSTALL_CERT = extract("install_acme_cert_pair", "install_manual_cert")

def make_cert(base: Path, domain: str, stem: str):
    key = base / f"{stem}.key"
    cert = base / f"{stem}.cer"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "3",
        "-subj", f"/CN={domain}", "-addext", f"subjectAltName=DNS:{domain}"
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cert, key

def run_case(status: int, cert_domain: str = "cert.example.test", include_key=True,
             port80_busy=False, mismatch_key=False, install_fail=False, existing_pair=False):
    with tempfile.TemporaryDirectory(prefix="jiedian-http01-") as td:
        base = Path(td)
        acme_home = base / "acme"
        domain_dir = acme_home / "cert.example.test_ecc"
        domain_dir.mkdir(parents=True)
        source_cert, source_key = make_cert(base, cert_domain, "fixture")
        (domain_dir / "fullchain.cer").write_bytes(source_cert.read_bytes())
        if include_key:
            if mismatch_key:
                _, wrong_key = make_cert(base, "other.example.test", "wrong-key")
                (domain_dir / "cert.example.test.key").write_bytes(wrong_key.read_bytes())
            else:
                (domain_dir / "cert.example.test.key").write_bytes(source_key.read_bytes())

        fakebin = base / "bin"
        fakebin.mkdir()
        (fakebin / "socat").write_text("#!/bin/sh\nexit 0\n")
        (fakebin / "socat").chmod(0o755)
        acme = acme_home / "acme.sh"
        acme_home.mkdir(exist_ok=True)
        acme.write_text('''#!/bin/sh
case "$1" in
  --set-default-ca) exit 0 ;;
  --issue) exit "${MOCK_ISSUE_STATUS:-2}" ;;
  --install-cert)
    key=""; cert=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --key-file) key=$2; shift 2 ;;
        --fullchain-file) cert=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$key" ] && [ -n "$cert" ] || exit 9
    mkdir -p "$(dirname "$key")" "$(dirname "$cert")"
    cp "$MOCK_SOURCE_KEY" "$key" || exit 8
    [ "${MOCK_INSTALL_FAIL:-0}" = 1 ] && exit 7
    cp "$MOCK_SOURCE_CERT" "$cert" || exit 8
    echo installed >> "$MOCK_INSTALL_LOG"
    exit 0
    ;;
esac
exit 10
''')
        acme.chmod(0o755)
        out = base / "out"
        out.mkdir()
        old_cert = old_key = None
        if existing_pair:
            old_cert_path, old_key_path = make_cert(base, "cert.example.test", "previous")
            old_cert, old_key = old_cert_path.read_bytes(), old_key_path.read_bytes()
            (out / "fullchain.pem").write_bytes(old_cert)
            (out / "privkey.pem").write_bytes(old_key)
        install_log = base / "install.log"
        harness = base / "harness.sh"
        harness.write_text(f'''#!/bin/sh
set -eu
ACME_HOME={str(acme_home)!r}
OS_FAMILY=debian
CERT_DIR={str(out)!r}
CERT_FILE={str(out / 'fullchain.pem')!r}
KEY_FILE={str(out / 'privkey.pem')!r}
RELOAD_HOOK=/bin/true
msg() {{ printf '%s\\n' "$*"; }}
warn() {{ printf '[WARN] %s\\n' "$*" >&2; }}
valid_cert_domain() {{ return 0; }}
port_listening() {{ [ "${{MOCK_PORT80_BUSY:-0}}" = 1 ]; }}
install_acme() {{ return 0; }}
run_with_timeout() {{ shift; "$@"; }}
chown() {{ return 0; }}
{HINT}
{LOGGED}
{ISSUE}
{CHECK}
{INSTALL_CERT}
if issue_http_cert cert.example.test; then exit 0; else exit 1; fi
''')
        env = os.environ.copy()
        env.update({
            "PATH": f"{fakebin}:{env.get('PATH','')}",
            "MOCK_ISSUE_STATUS": str(status),
            "MOCK_PORT80_BUSY": "1" if port80_busy else "0",
            "MOCK_SOURCE_CERT": str(source_cert),
            "MOCK_SOURCE_KEY": str(source_key),
            "MOCK_INSTALL_LOG": str(install_log),
            "MOCK_INSTALL_FAIL": "1" if install_fail else "0",
        })
        proc = subprocess.run(["sh", str(harness)], env=env, text=True, capture_output=True)
        outputs_exist = (out / "fullchain.pem").is_file() and (out / "privkey.pem").is_file()
        installed = install_log.exists()
        restored = None
        if existing_pair:
            restored = ((out / "fullchain.pem").read_bytes() == old_cert and
                        (out / "privkey.pem").read_bytes() == old_key)
        return proc, outputs_exist, installed, restored

# acme.sh code 2 means renewal was skipped: validate and reuse the stored ECC cert.
p, outputs_exist, installed, _ = run_case(2)
assert p.returncode == 0, p.stdout + p.stderr
assert outputs_exist
assert "复用现有证书" in p.stdout and installed
print("PASS: HTTP-01 acme.sh exit 2 reuses a valid, matching certificate/key")

# Fresh issuance (exit 0) still installs and validates the cert.
p, outputs_exist, installed, _ = run_case(0)
assert p.returncode == 0, p.stdout + p.stderr
assert outputs_exist and installed
print("PASS: HTTP-01 acme.sh exit 0 installs a newly issued certificate")

# A real ACME error must fail closed and must not install a certificate.
p, outputs_exist, installed, _ = run_case(1)
assert p.returncode != 0 and not installed
print("PASS: HTTP-01 ACME errors fail without installing a certificate")

# Exit 2 without the stored private key must not be treated as success.
p, outputs_exist, installed, _ = run_case(2, include_key=False)
assert p.returncode != 0 and not installed
print("PASS: HTTP-01 exit 2 without the private key is rejected")

# Exit 2 with a cert for another hostname must not be reused.
p, outputs_exist, installed, _ = run_case(2, cert_domain="wrong.example.test")
assert p.returncode != 0 and not installed
print("PASS: HTTP-01 exit 2 with a hostname-mismatched cert is rejected")

# A busy TCP/80 listener must not block reuse when ACME says renewal is not due.
p, outputs_exist, installed, _ = run_case(2, port80_busy=True)
assert p.returncode == 0, p.stdout + p.stderr
assert outputs_exist and installed
print("PASS: valid non-due certificate is reused even when TCP/80 is already occupied")

# A certificate and unrelated private key must never be reused.
p, outputs_exist, installed, _ = run_case(2, mismatch_key=True)
assert p.returncode != 0 and not installed
print("PASS: HTTP-01 rejects a certificate/private-key mismatch")

# A partial ACME install must restore the previous live certificate and private key.
p, outputs_exist, installed, restored = run_case(0, install_fail=True, existing_pair=True)
assert p.returncode != 0 and outputs_exist and not installed and restored, p.stdout + p.stderr
print("PASS: failed/partial ACME certificate install rolls back the previous pair")
