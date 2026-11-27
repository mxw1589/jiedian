#!/usr/bin/env python3
"""Regression tests for schema-9 port validation and reservation."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
match = re.search(r"(?ms)^assign_ports\(\) \{.*?^\}\n(?=\nask_ports\(\))", SOURCE)
assert match, "assign_ports function not found"
ASSIGN = match.group(0)

COMMON = r'''#!/bin/sh
set -eu
PORT_HISTORY='{}'
web_schema=9
ENABLE_ANYTLS=1
ENABLE_WS_TLS=0
ENABLE_WS_ARGO=0
ENABLE_SS2022=0
ENABLE_VLESS_REALITY=0
ENABLE_NAIVE=0
ENABLE_ANYTLS_REALITY=0
ENABLE_SNELL_V6=0
ANYTLS_PORT=''
WS_PORT=''
ARGO_PORT=''
SS2022_PORT=''
REALITY_PORT=''
NAIVE_PORT=''
ANYREALITY_PORT=''
SNELL_V6_PORT=''
PREVIOUS_ANYTLS_PORT=''
PREVIOUS_WS_PORT=''
PREVIOUS_REALITY_PORT=''
PREVIOUS_NAIVE_PORT=''
PREVIOUS_ANYREALITY_PORT=''
PREVIOUS_ARGO_PORT=''
PREVIOUS_SS2022_PORT=''
PREVIOUS_SNELL_V6_PORT=''
trim_value() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
normalize_optional_port() {
  value=$(trim_value "$1")
  [ -n "$value" ] || return 0
  case "$value" in *[!0-9]*) return 1 ;; esac
  [ "$value" -ge 1024 ] 2>/dev/null && [ "$value" -le 65535 ] 2>/dev/null || return 1
  printf '%s\n' "$value" | sed 's/^0*//'
}
manual_port_available() { [ "$1" != "${MOCK_BUSY_PORT:-}" ]; }
pick_random_range_port() { printf '%s\n' "$*" >> "$PORT_ARGS_LOG"; printf '20001\n'; }
pick_random_ws_port() { printf '2083\n'; }
msg() { printf '%s\n' "$*"; }
warn() { :; }
err() { printf '%s\n' "$*" >&2; exit 1; }
'''

def run_case(extra: str, env_extra=None):
    with tempfile.TemporaryDirectory(prefix="jiedian-ports-") as td:
        log = Path(td) / "port-args.log"
        harness = Path(td) / "test.sh"
        harness.write_text(COMMON + extra + "\n" + ASSIGN + "\nassign_ports\n", encoding="utf-8")
        env = os.environ.copy()
        env["PORT_ARGS_LOG"] = str(log)
        if env_extra:
            env.update(env_extra)
        proc = subprocess.run(["sh", str(harness)], env=env, text=True, capture_output=True)
        return proc, log.read_text(encoding="utf-8") if log.exists() else ""

# Schema 8 must reject duplicate manually supplied ports rather than silently reassigning one.
p, _ = run_case("ENABLE_WS_TLS=1\nANYTLS_PORT=20000\nWS_PORT=20000")
assert p.returncode != 0 and "重复" in p.stderr, p.stdout + p.stderr
print("PASS: schema 9 rejects duplicate selected ports")

# Schema 8 must reject an occupied manual port rather than silently selecting another port.
p, _ = run_case("ANYTLS_PORT=20000", {"MOCK_BUSY_PORT": "20000"})
assert p.returncode != 0 and "已被占用" in p.stderr, p.stdout + p.stderr
print("PASS: schema 9 rejects an occupied manual port")

# A random earlier port must reserve every later manual port before allocation.
p, args = run_case("ENABLE_WS_TLS=1\nANYTLS_PORT=''\nWS_PORT=20000")
assert p.returncode == 0, p.stdout + p.stderr
assert "20000" in args, args
assert "AnyTLS=20001" in p.stdout and "WS TLS=20000" in p.stdout, p.stdout
print("PASS: schema 9 reserves later manual ports before random allocation")

# Snell v6 is a TCP-only inbound and participates in schema-9 port collision checks.
p, _ = run_case("ENABLE_SNELL_V6=1\nSNELL_V6_PORT=21000")
assert p.returncode == 0 and "Snell v6=21000" in p.stdout, p.stdout + p.stderr
p, _ = run_case("ENABLE_SNELL_V6=1\nSNELL_V6_PORT=20000\nANYTLS_PORT=20000")
assert p.returncode != 0 and "Snell v6" in p.stderr, p.stdout + p.stderr
print("PASS: schema 9 allocates Snell v6 TCP port and rejects cross-protocol duplicates")
