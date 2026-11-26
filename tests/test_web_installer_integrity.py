#!/usr/bin/env python3
"""The browser installer must pin the exact Shell artifact before replacement."""
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
html = (ROOT / "index.html").read_text(encoding="utf-8")
shell = (ROOT / "sb-manager-debian-alpine.sh").read_bytes()
expected = re.search(r'const EXPECTED_SHA256="([0-9a-f]{64})";', html)
assert expected, "expected SHA-256 pin missing or malformed"
actual = hashlib.sha256(shell).hexdigest()
assert expected.group(1) == actual, f"HTML SHA-256 pin mismatch: expected {expected.group(1)}, actual {actual}"
assert 'const EXPECTED_VERSION="1.4.3";' in html
assert "grep -qx '# PROJECT_VERSION=${EXPECTED_VERSION}' \"$SH\"" in html
assert 'sh -n "$SH"' in html
assert 'sha256sum "$SH"' in html and 'busybox sha256sum "$SH"' in html
assert 'install -m 0700 "$SH" "$MANAGER_TMP"' in html
assert 'mv -f "$MANAGER_TMP" "$MANAGER_PATH"' in html
assert 'mv -f "$MANAGER_BACKUP" "$MANAGER_PATH"' in html
assert 'WEB_INSTALL_INTEGRITY=1' in html and 'WEB_MANAGER_LOCK=1' in html

# Render the actual command template and parse it with POSIX sh.
if shutil.which("node"):
    with tempfile.TemporaryDirectory(prefix="jiedian-web-command-") as td:
        generated = Path(td) / "generated-install.sh"
        node_script = """
const fs=require("fs");
const html=fs.readFileSync(process.argv[1],"utf8");
const start=html.indexOf("function oneCommandText(c){");
const end=html.indexOf("\\nfunction setEnabled",start);
const snippet=html.slice(start,end);
const RAW_URL="https://raw.githubusercontent.com/mxw1589/jiedian/main/sb-manager-debian-alpine.sh";
const EXPECTED_VERSION="1.4.3";
const EXPECTED_SHA256="CHECKSUM";
const protocolLabels={anytls:"AnyTLS",ws_tls:"直连 WS TLS",ws_argo:"Argo WS TLS",ss2022:"Shadowsocks 2022",vless_reality:"VLESS + Reality",naive:"NaiveProxy",anytls_reality:"AnyTLS + Reality"};
const selectedNames=p=>Object.entries(protocolLabels).filter(([key])=>p[key]).map(([,label])=>label).join("、");
const b64=s=>Buffer.from(s,"utf8").toString("base64");
eval(snippet+"; process.stdout.write(oneCommandText({protocols:{ws_argo:true}}));");
""".replace("CHECKSUM", expected.group(1))
        result = subprocess.run(
            ["node", "-e", node_script, str(ROOT / "index.html")],
            text=True, capture_output=True, check=True
        )
        generated.write_text(result.stdout, encoding="utf-8")
        subprocess.run(["sh", "-n", str(generated)], check=True)

print("PASS: Web installer pins exact Shell SHA-256/version, syntax-checks, atomically replaces, restores previous manager, and emits valid POSIX shell")
