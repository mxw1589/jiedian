#!/usr/bin/env python3
# The manager lock serializes writes and safely recovers stale PID locks.
from pathlib import Path
import os, subprocess, tempfile, shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
start = SOURCE.index("release_manager_lock() {")
end = SOURCE.index("\n}\n\ndetect_service_manager()", start) + 2
FUNCTIONS = SOURCE[start:end]

shells = [["sh"]]
if shutil.which("dash"):
    shells.append(["dash"])
if shutil.which("busybox"):
    shells.append(["busybox", "sh"])

for shell in shells:
  with tempfile.TemporaryDirectory(prefix="jiedian-lock-") as td:
      base = Path(td)
      lock = base / "manager.lock"
      harness = base / "test.sh"
      harness.write_text(f'''#!/bin/sh
  set -eu
  LOCK_DIR={str(lock)!r}
  manager_lock_owned=0
  err() {{ echo "$*" >&2; exit 1; }}
  {FUNCTIONS}
  acquire_manager_lock
  echo acquired
  ''', encoding="utf-8")
  
      # Lock is acquired and released automatically on normal process exit.
      result = subprocess.run([*shell, str(harness)], text=True, capture_output=True, check=True)
      assert "acquired" in result.stdout and not lock.exists()
  
      # A live PID prevents a second writer.
      sleeper = subprocess.Popen(["sleep", "10"])
      try:
          lock.mkdir(); (lock / "pid").write_text(str(sleeper.pid), encoding="utf-8")
          result = subprocess.run([*shell, str(harness)], text=True, capture_output=True)
          assert result.returncode != 0 and "另一个管理器实例" in result.stderr
          assert lock.exists()
      finally:
          sleeper.terminate(); sleeper.wait()
  
      # Stale PID is moved aside and the new process can proceed.
      (lock / "pid").write_text("99999999\n", encoding="utf-8")
      result = subprocess.run([*shell, str(harness)], text=True, capture_output=True, check=True)
      assert "acquired" in result.stdout and not lock.exists()
  
print("PASS: Manager lock blocks concurrent writers and recovers stale PID locks under sh/dash/BusyBox ash where available")
