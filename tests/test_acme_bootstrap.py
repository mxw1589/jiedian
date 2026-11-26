#!/usr/bin/env python3
"""Test ACME bootstrap fallback when GitHub is unreachable."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "sb-manager-debian-alpine.sh").read_text(encoding="utf-8")

def function(name):
    match = re.search(r"(?ms)^" + re.escape(name) + r"\(\) \{\n.*?^\}$", SOURCE)
    assert match, f"function not found: {name}"
    return match.group(0)

DOWNLOAD = function("acme_download_official_source")
INSTALL_DIR = function("acme_install_from_source_dir")
INSTALL_PACKAGE = function("acme_install_from_system_package")

assert "https://github.com/acmesh-official/acme.sh/archive/refs/heads/master.tar.gz" in DOWNLOAD
assert "https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/heads/master" in DOWNLOAD
assert "apt-get install -y acme.sh" in INSTALL_PACKAGE
assert "apk add --no-cache acme.sh" in INSTALL_PACKAGE
assert "/usr/share/acme.sh" in INSTALL_PACKAGE
assert "--home /root/.acme.sh --nocron" in INSTALL_DIR

with tempfile.TemporaryDirectory(prefix="jiedian-acme-bootstrap-") as td:
    base = Path(td)
    fakebin = base / "bin"
    fakebin.mkdir()
    pkg = base / "pkg"
    (pkg / "dnsapi").mkdir(parents=True)
    (pkg / "acme.sh").write_text(
        '#!/bin/sh\n'
        'printf "%s\\n" "$@" > "$ACME_ARGS"\n'
        'mkdir -p "$ACME_HOME"\n'
        'printf "#!/bin/sh\\nexit 0\\n" > "$ACME_HOME/acme.sh"\n'
        'chmod 700 "$ACME_HOME/acme.sh"\n',
        encoding="utf-8"
    )
    (pkg / "acme.sh").chmod(0o755)

    # Debian package fallback: apt-cache sees the package; apt-get installs it.
    (fakebin / "apt-cache").write_text('#!/bin/sh\n[ "$1" = show ] && [ "$2" = acme.sh ]\n', encoding="utf-8")
    (fakebin / "apt-get").write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$APT_LOG"\nexit 0\n', encoding="utf-8")
    for name in ("apt-cache", "apt-get"):
        (fakebin / name).chmod(0o755)

    home = base / "home"
    args_file = base / "args"
    apt_log = base / "apt.log"
    code = INSTALL_DIR + "\n" + INSTALL_PACKAGE
    code = code.replace("/root/.acme.sh", str(home)).replace("/usr/share/acme.sh", str(pkg))
    harness = base / "debian-test.sh"
    harness.write_text(
        'set -eu\n'
        'msg() { :; }\nwarn() { :; }\n'
        'OS_FAMILY=debian\n'
        + code +
        '\nacme_install_from_system_package "tester@example.com"\n'
        'test -x "' + str(home / "acme.sh") + '"\n',
        encoding="utf-8"
    )
    env = os.environ.copy()
    env.update({
        "PATH": str(fakebin) + os.pathsep + env.get("PATH", ""),
        "ACME_HOME": str(home),
        "ACME_ARGS": str(args_file),
        "APT_LOG": str(apt_log),
    })
    subprocess.run(["/bin/sh", str(harness)], env=env, check=True)
    apt_text = apt_log.read_text(encoding="utf-8")
    args_text = args_file.read_text(encoding="utf-8")
    assert "install\n-y\nacme.sh" in apt_text
    assert "--home" in args_text and str(home) in args_text
    assert "--nocron" in args_text and "--accountemail" in args_text
    assert "tester@example.com" in args_text

    # Alpine package fallback: apk add is used only after package absence.
    alpine_bin = base / "alpine-bin"
    alpine_bin.mkdir()
    apk_log = base / "apk.log"
    apk = alpine_bin / "apk"
    apk.write_text(
        '#!/bin/sh\n'
        'printf "%s\\n" "$@" >> "$APK_LOG"\n'
        'if [ "$1" = info ]; then exit 1; fi\n'
        'if [ "$1" = add ] && [ "$2" = --no-cache ] && [ "$3" = acme.sh ]; then exit 0; fi\n'
        'exit 1\n',
        encoding="utf-8"
    )
    apk.chmod(0o755)
    alpine_home = base / "alpine-home"
    alpine_args = base / "alpine-args"
    alpine_code = INSTALL_DIR + "\n" + INSTALL_PACKAGE
    alpine_code = alpine_code.replace("/root/.acme.sh", str(alpine_home)).replace("/usr/share/acme.sh", str(pkg))
    alpine_harness = base / "alpine-test.sh"
    alpine_harness.write_text(
        'set -eu\nmsg() { :; }\nwarn() { :; }\n'
        'OS_FAMILY=alpine\n' + alpine_code +
        '\nacme_install_from_system_package ""\n'
        'test -x "' + str(alpine_home / "acme.sh") + '"\n',
        encoding="utf-8"
    )
    env2 = env.copy()
    env2.update({
        "PATH": str(alpine_bin) + os.pathsep + env.get("PATH", ""),
        "ACME_HOME": str(alpine_home),
        "ACME_ARGS": str(alpine_args),
        "APK_LOG": str(apk_log),
    })
    subprocess.run(["/bin/sh", str(alpine_harness)], env=env2, check=True)
    assert "add\n--no-cache\nacme.sh" in apk_log.read_text(encoding="utf-8")

    # GitHub is blocked but the second official GitHub content host works.
    fixture = base / "fixture"
    (fixture / "acme.sh-master" / "dnsapi").mkdir(parents=True)
    (fixture / "acme.sh-master" / "acme.sh").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    (fixture / "acme.sh-master" / "dnsapi" / "dns_cf.sh").write_text("# fixture\n", encoding="utf-8")
    tar_path = base / "fixture.tar.gz"
    with tarfile.open(tar_path, "w:gz") as archive:
        archive.add(fixture / "acme.sh-master", arcname="acme.sh-master")

    curl = fakebin / "curl"
    curl.write_text(
        '#!/bin/sh\n'
        'out=""\nurl=""\n'
        'while [ "$#" -gt 0 ]; do\n'
        ' case "$1" in -o) out=$2; shift 2;; http*) url=$1; shift;; *) shift;; esac\n'
        'done\n'
        'printf "%s\\n" "$url" >> "$CURL_LOG"\n'
        'case "$url" in\n'
        ' *github.com/acmesh-official/acme.sh/archive*) exit 7;;\n'
        ' *codeload.github.com/acmesh-official/acme.sh/tar.gz*) cp "$FIXTURE_TAR" "$out"; exit 0;;\n'
        ' *) exit 22;;\n'
        'esac\n',
        encoding="utf-8"
    )
    curl.chmod(0o755)
    download_tmp = base / "download"
    download_tmp.mkdir()
    download_harness = base / "download-test.sh"
    download_harness.write_text(
        'set -eu\nmsg() { :; }\nwarn() { :; }\n'
        + DOWNLOAD +
        '\nacme_download_official_source "' + str(download_tmp) + '"\n'
        'test -s "$ACME_SOURCE_DIR/acme.sh"\n'
        'test -d "$ACME_SOURCE_DIR/dnsapi"\n',
        encoding="utf-8"
    )
    env3 = env.copy()
    env3.update({
        "CURL_LOG": str(base / "curl.log"),
        "FIXTURE_TAR": str(tar_path),
    })
    subprocess.run(["/bin/sh", str(download_harness)], env=env3, check=True)
    curl_log = (base / "curl.log").read_text(encoding="utf-8")
    assert "github.com/acmesh-official/acme.sh/archive" in curl_log
    assert "codeload.github.com/acmesh-official/acme.sh/tar.gz" in curl_log

print("PASS: ACME bootstrap retries official source host and falls back to Debian APT / Alpine APK")
