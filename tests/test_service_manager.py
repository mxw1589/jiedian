#!/usr/bin/env python3
# Service-manager detection must require a real runtime, not just binaries.
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")
start = SOURCE.index("detect_service_manager() {")
end = SOURCE.index("\n}\n\nread_sysctl_value()", start) + 2
FUNCTION = SOURCE[start:end]

shells = [["sh"]]
if shutil.which("dash"):
    shells.append(["dash"])
if shutil.which("busybox"):
    shells.append(["busybox", "sh"])

for shell in shells:
    with tempfile.TemporaryDirectory(prefix="jiedian-service-detect-") as td:
        base = Path(td)
        bindir = base / "bin"
        bindir.mkdir()
        for name in ("systemctl", "rc-service", "rc-update"):
            f = bindir / name
            f.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            f.chmod(0o755)
        systemd = base / "systemd"
        openrc = base / "openrc"
        harness = base / "test.sh"
        function = FUNCTION.replace("/run/systemd/system", str(systemd)).replace("/run/openrc", str(openrc))
        harness.write_text(
            "#!/bin/sh\n" + function + "\ndetect_service_manager || exit 1\necho SERVICE_KIND=$SERVICE_KIND\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env["PATH"] = str(bindir) + os.pathsep + env["PATH"]

        # Neither runtime directory exists: binaries alone must not select a manager.
        result = subprocess.run([*shell, str(harness)], env=env, text=True, capture_output=True)
        assert result.returncode != 0

        # OpenRC runtime present -> OpenRC selected.
        openrc.mkdir()
        result = subprocess.run([*shell, str(harness)], env=env, text=True, capture_output=True, check=True)
        assert "SERVICE_KIND=openrc" in result.stdout

        # Active systemd takes precedence when both are available.
        systemd.mkdir()
        result = subprocess.run([*shell, str(harness)], env=env, text=True, capture_output=True, check=True)
        assert "SERVICE_KIND=systemd" in result.stdout

print("PASS: Service manager detection requires active systemd/OpenRC runtime under sh/dash/BusyBox ash where available")
