#!/usr/bin/env python3
# Cron ownership regression: only remove the manager-marked block.
from pathlib import Path
import os, subprocess, tempfile, shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

def extract(name, next_name):
    start = SOURCE.index(f"{name}() {{")
    end = SOURCE.index(f"\n}}\n\n{next_name}", start) + 2
    return SOURCE[start:end]

ENSURE = extract("ensure_acme_cron", "start_cron")
start_remove = SOURCE.index("remove_acme_cron_entry() {")
end_remove = SOURCE.index("\n}\n\n\nsave_uninstall_port_history()", start_remove) + 2
REMOVE = SOURCE[start_remove:end_remove]
BEGIN = "# BEGIN SB-MANAGER ACME RENEWAL"
END = "# END SB-MANAGER ACME RENEWAL"
COMMAND = "17 3 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null 2>&1"
MATCH = "/root/.acme.sh/acme.sh --cron --home /root/.acme.sh"

shells = [["sh"]]
if shutil.which("dash"):
    shells.append(["dash"])
if shutil.which("busybox"):
    shells.append(["busybox", "sh"])

for shell in shells:
  with tempfile.TemporaryDirectory(prefix="jiedian-cron-") as td:
      base = Path(td)
      bindir = base / "bin"; bindir.mkdir()
      crontab_file = base / "root.crontab"
      fake = bindir / "crontab"
      fake.write_text('''#!/bin/sh
  case "$1" in
    -l) [ -f "$CRON_FILE" ] && cat "$CRON_FILE" || exit 1 ;;
    -) cat > "$CRON_FILE" ;;
    -r) rm -f "$CRON_FILE" ;;
    *) exit 2 ;;
  esac
  ''', encoding="utf-8")
      fake.chmod(0o755)
      env = os.environ.copy(); env["PATH"] = str(bindir) + os.pathsep + env["PATH"]; env["CRON_FILE"] = str(crontab_file)
      constants = f'''ACME_CRON_BEGIN={BEGIN!r}
  ACME_CRON_END={END!r}
  ACME_CRON_COMMAND={COMMAND!r}
  ACME_CRON_MATCH={MATCH!r}
  warn() {{ echo "$*" >&2; }}
  '''
      harness = base / "test.sh"
      # Existing user jobs are preserved and the manager block is added exactly once.
      crontab_file.write_text("0 4 * * * /usr/local/bin/user-backup\n", encoding="utf-8")
      harness.write_text("#!/bin/sh\nset -eu\n" + constants + ENSURE + "\nensure_acme_cron\n", encoding="utf-8")
      subprocess.run([*shell, str(harness)], env=env, check=True)
      first = crontab_file.read_text(encoding="utf-8")
      assert "0 4 * * * /usr/local/bin/user-backup" in first
      assert first.count(BEGIN) == 1 and first.count(END) == 1 and first.count(COMMAND) == 1
      subprocess.run([*shell, str(harness)], env=env, check=True)
      second = crontab_file.read_text(encoding="utf-8")
      assert second.count(COMMAND) == 1
  
      # Uninstall removes only the marked block, not unrelated user jobs.
      harness.write_text("#!/bin/sh\nset -eu\n" + constants + REMOVE + "\nremove_acme_cron_entry\n", encoding="utf-8")
      subprocess.run([*shell, str(harness)], env=env, check=True)
      remaining = crontab_file.read_text(encoding="utf-8")
      assert "0 4 * * * /usr/local/bin/user-backup" in remaining
      assert BEGIN not in remaining and END not in remaining and MATCH not in remaining
  
      # Legacy unmarked acme.sh lines are intentionally preserved to avoid deleting user jobs.
      legacy = "25 2 * * * /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >/dev/null 2>&1\n"
      crontab_file.write_text("0 4 * * * /usr/local/bin/user-backup\n" + legacy, encoding="utf-8")
      subprocess.run([*shell, str(harness)], env=env, check=True)
      assert legacy.strip() in crontab_file.read_text(encoding="utf-8")
  
print("PASS: Cron ownership and safe uninstall under sh/dash/BusyBox ash where available")
