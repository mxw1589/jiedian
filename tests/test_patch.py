#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patch_sb", ROOT / "patch_sb.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

# Mirrors the relevant source layout reported by a real v26.4.11 installation:
# the blank line between `fi` and the OpenVZ branch is intentional.
FIXTURE_WITH_BLANK = r"""#!/bin/bash
stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null
if [[ ! -f /some/first-run-marker ]]; then
  touch sbyg_update
fi

if [[ $vi = openvz ]]; then
TUN=$(cat /dev/net/tun 2>&1)
fi
cfargo_ym(){
tls=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[1].tls.enabled')
if [[ "$tls" = "false" ]]; then
echo "argo allowed"
else
yellow "因vmess开启了tls，Argo隧道功能不可用" && sleep 2
fi
}
"""

FIXTURE_WITHOUT_BLANK = FIXTURE_WITH_BLANK.replace(
    "touch sbyg_update\nfi\n\nif [[ $vi = openvz ]]; then",
    "touch sbyg_update\nfi\nif [[ $vi = openvz ]]; then",
)

FIXTURE_WITH_MULTIPLE_BLANKS = FIXTURE_WITH_BLANK.replace(
    "touch sbyg_update\nfi\n\nif [[ $vi = openvz ]]; then",
    "touch sbyg_update\nfi\n\n\n\nif [[ $vi = openvz ]]; then",
)


class PatchTests(unittest.TestCase):
    def assert_dependency_block_before_openvz(self, patched):
        marker = "# BEGIN SING-BOX-YG RUNTIME DEPENDENCY SELF-HEAL"
        self.assertEqual(patched.count(marker), 1)
        self.assertLess(patched.index(marker), patched.index("if [[ $vi = openvz ]]; then"))
        self.assertIn("# END SING-BOX-YG RUNTIME DEPENDENCY SELF-HEAL", patched)

    def test_actual_user_layout_with_one_blank_line(self):
        patched, changed = mod.patch_text(FIXTURE_WITH_BLANK)
        self.assertTrue(changed)
        self.assertIn("if [[ -t 0 && -t 1 ]]; then", patched)
        self.assertIn("jq -r '.inbounds[1].tls.enabled // empty'", patched)
        self.assert_dependency_block_before_openvz(patched)

    def test_legacy_layout_without_blank_line(self):
        patched, changed = mod.patch_text(FIXTURE_WITHOUT_BLANK)
        self.assertTrue(changed)
        self.assert_dependency_block_before_openvz(patched)

    def test_multiple_blank_lines_are_supported(self):
        patched, changed = mod.patch_text(FIXTURE_WITH_MULTIPLE_BLANKS)
        self.assertTrue(changed)
        self.assert_dependency_block_before_openvz(patched)

    def test_consistent_crlf_source_preserves_line_endings(self):
        source = FIXTURE_WITH_BLANK.replace("\n", "\r\n")
        patched, changed = mod.patch_text(source)
        self.assertTrue(changed)
        self.assert_dependency_block_before_openvz(patched)
        self.assertEqual(patched.count("\n"), patched.count("\r\n"))

    def test_patch_is_idempotent(self):
        patched, changed = mod.patch_text(FIXTURE_WITH_BLANK)
        patched2, changed2 = mod.patch_text(patched)
        self.assertTrue(changed)
        self.assertFalse(changed2)
        self.assertEqual(patched, patched2)

    def test_duplicate_dependency_anchor_is_rejected(self):
        duplicate = FIXTURE_WITH_BLANK + "\ntouch sbyg_update\nfi\n\nif [[ $vi = openvz ]]; then\n"
        with self.assertRaisesRegex(RuntimeError, "匹配数：2"):
            mod.patch_text(duplicate)

    def test_nonblank_statement_between_dependency_anchor_is_rejected(self):
        modified = FIXTURE_WITH_BLANK.replace(
            "touch sbyg_update\nfi\n\nif [[ $vi = openvz ]]; then",
            "touch sbyg_update\nfi\necho unexpected\nif [[ $vi = openvz ]]; then",
        )
        with self.assertRaisesRegex(RuntimeError, "匹配数：0"):
            mod.patch_text(modified)

    def test_unknown_source_is_rejected(self):
        with self.assertRaises(RuntimeError):
            mod.patch_text("#!/bin/bash\necho not the upstream source\n")

    def test_preflight_returns_patch_without_modifying_target(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "sb"
            version = Path(temp_dir) / "v"
            target.write_text(FIXTURE_WITH_BLANK, encoding="utf-8")
            version.write_text("v26.4.11\n", encoding="utf-8")
            old_target, old_version = mod.TARGET, mod.VERSION_FILE
            try:
                mod.TARGET, mod.VERSION_FILE = target, version
                original, updated, changed = mod.load_and_validate()
                self.assertTrue(changed)
                self.assertEqual(original, FIXTURE_WITH_BLANK)
                self.assertNotEqual(updated, original)
                self.assertEqual(target.read_text(encoding="utf-8"), FIXTURE_WITH_BLANK)
            finally:
                mod.TARGET, mod.VERSION_FILE = old_target, old_version

    def test_preflight_rejects_version_mismatch(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            target = Path(temp_dir) / "sb"
            version = Path(temp_dir) / "v"
            target.write_text(FIXTURE_WITH_BLANK, encoding="utf-8")
            version.write_text("v26.5.0\n", encoding="utf-8")
            old_target, old_version = mod.TARGET, mod.VERSION_FILE
            try:
                mod.TARGET, mod.VERSION_FILE = target, version
                with self.assertRaisesRegex(RuntimeError, "仅针对 v26.4.11"):
                    mod.load_and_validate()
                self.assertEqual(target.read_text(encoding="utf-8"), FIXTURE_WITH_BLANK)
            finally:
                mod.TARGET, mod.VERSION_FILE = old_target, old_version


if __name__ == "__main__":
    unittest.main()
