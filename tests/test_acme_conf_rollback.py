#!/usr/bin/env python3
# First-time failed DNS-01 attempts must not leave newly persisted credentials.
from pathlib import Path
import subprocess, tempfile, shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
start = SOURCE.index("restore_acme_cf_credentials() {")
end = SOURCE.index("\n}\n\nissue_cloudflare_cert()", start) + 2
FUNCTION = SOURCE[start:end]

shells = [["sh"]]
if shutil.which("dash"):
    shells.append(["dash"])
if shutil.which("busybox"):
    shells.append(["busybox", "sh"])

for shell in shells:
  with tempfile.TemporaryDirectory(prefix="jiedian-acme-rollback-") as td:
      base = Path(td)
      conf = base / "example.com.conf"
      backup = base / "example.com.conf.backup"
      harness = base / "test.sh"
  
      # No config existed before this run: remove the newly-created file.
      conf.write_text("CF_Token='new-secret'\n", encoding="utf-8")
      harness.write_text(f'''#!/bin/sh
  set -eu
  acme_conf_backup=""
  acme_conf_existed=0
  acme_domain_conf={str(conf)!r}
  warn() {{ echo "$*" >&2; }}
  {FUNCTION}
  restore_acme_cf_credentials
  ''', encoding="utf-8")
      subprocess.run([*shell, str(harness)], check=True)
      assert not conf.exists()
  
      # A pre-existing config is restored byte-for-byte from its backup.
      conf.write_text("CF_Token='changed-secret'\n", encoding="utf-8")
      backup.write_text("Le_Webroot='dns_cf'\nCF_Token='old-secret'\n", encoding="utf-8")
      harness.write_text(f'''#!/bin/sh
  set -eu
  acme_conf_backup={str(backup)!r}
  acme_conf_existed=1
  acme_domain_conf={str(conf)!r}
  warn() {{ echo "$*" >&2; }}
  {FUNCTION}
  restore_acme_cf_credentials
  ''', encoding="utf-8")
      subprocess.run([*shell, str(harness)], check=True)
      assert conf.read_text(encoding="utf-8") == "Le_Webroot='dns_cf'\nCF_Token='old-secret'\n"
      assert not backup.exists()
  
print("PASS: DNS-01 rollback under sh/dash/BusyBox ash where available")
