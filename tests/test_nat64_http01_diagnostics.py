#!/usr/bin/env python3
"""Regression tests for NAT64 egress reporting and Cloudflare HTTP-01 diagnostics."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}()", start) + 2
    return SOURCE[start:end]

VALID_IPV4 = extract("valid_ipv4_address", "valid_ipv6_literal")
NAT64 = extract("detect_nat64_public_ipv4", "resolve_install_addresses")
HINT = extract("http01_failure_hint", "run_http01_issue_logged")
LOGGED = extract("run_http01_issue_logged", "issue_http_cert")

assert "curl -6" in NAT64
assert "ipv4.icanhazip.com" in NAT64 and "v4.ident.me" in NAT64
assert "NAT64 出站测试：成功" in SOURCE
assert "不能填写为源站 IPv4" in SOURCE
assert "apt-get install -y --no-install-recommends cron" in SOURCE
assert "Invalid response.*: *521" in HINT
assert "NAT64 出站成功不代表公网 IPv4 入站可用" in HINT
assert "DNS only" in HINT and "Cloudflare DNS-01" in HINT

with tempfile.TemporaryDirectory(prefix="jiedian-nat64-test-") as td:
    root = Path(td)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    curl = bin_dir / "curl"
    curl.write_text(
        '#!/bin/sh\n'
        'printf "%s\\n" "$*" >> "$CURL_CALLS"\n'
        'case "$*" in\n'
        '  *ipv4.icanhazip.com*) exit 7 ;;\n'
        '  *v4.ident.me*) printf "%s\\n" "$NAT64_RESULT"; exit 0 ;;\n'
        'esac\n'
        'exit 22\n',
        encoding="utf-8"
    )
    curl.chmod(0o755)
    harness = root / "nat64-test.sh"
    harness.write_text(
        'set -eu\n'
        + VALID_IPV4 + '\n' + NAT64 +
        '\nresult=$(detect_nat64_public_ipv4)\n'
        '[ "$result" = "198.51.100.7" ]\n',
        encoding="utf-8"
    )
    env = os.environ.copy()
    env.update({
        "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
        "NAT64_RESULT": "198.51.100.7",
        "CURL_CALLS": str(root / "curl.calls"),
    })
    subprocess.run(["/bin/sh", str(harness)], env=env, check=True)
    calls = (root / "curl.calls").read_text(encoding="utf-8")
    assert "-6" in calls
    assert "ipv4.icanhazip.com" in calls and "v4.ident.me" in calls

    # A failed IPv4-only request must not be misreported as NAT64 success.
    curl.write_text('#!/bin/sh\nexit 7\n', encoding="utf-8")
    curl.chmod(0o755)
    fail_harness = root / "nat64-fail.sh"
    fail_harness.write_text(
        'set -eu\n' + VALID_IPV4 + '\n' + NAT64 +
        '\nif detect_nat64_public_ipv4; then exit 9; else exit 0; fi\n',
        encoding="utf-8"
    )
    subprocess.run(["/bin/sh", str(fail_harness)], env=env, check=True)

    # A 521 ACME response gets a targeted, actionable diagnosis.
    log = root / "acme.log"
    log.write_text(
        'Invalid status. Verification error details: 2606:4700::1: '
        'Invalid response from http://example.test/.well-known/acme-challenge/token: 521\n',
        encoding="utf-8"
    )
    hint_harness = root / "hint-test.sh"
    hint_harness.write_text(
        'set -eu\nwarn() { printf "WARN:%s\\n" "$*"; }\n' + HINT +
        '\nhttp01_failure_hint "$1"\n',
        encoding="utf-8"
    )
    result = subprocess.run(
        ["/bin/sh", str(hint_harness), str(log)],
        capture_output=True, text=True, check=True
    ).stdout
    assert "Cloudflare HTTP 521" in result
    assert "NAT64" in result and "DNS only" in result and "DNS-01" in result

    # The logged runner streams output and records the original command status.
    log2 = root / "stream.log"
    status = root / "status"
    logged_harness = root / "logged-test.sh"
    logged_harness.write_text(
        'set -eu\n' + LOGGED +
        '\nrun_http01_issue_logged "$1" "$2" sh -c "echo challenge-failed; exit 23" >/dev/null\n'
        '[ "$(cat "$2")" = 23 ]\n',
        encoding="utf-8"
    )
    subprocess.run(["/bin/sh", str(logged_harness), str(log2), str(status)], check=True)
    assert "challenge-failed" in log2.read_text(encoding="utf-8")

print("PASS: NAT64 IPv4-only egress detection, no inbound-address confusion, Cloudflare 521 diagnostics, and streamed ACME status capture")
