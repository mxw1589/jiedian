#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("patch_sb", ROOT / "patch_sb.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

FIXTURE = r"""#!/bin/bash
stty erase $'\b' 2>/dev/null || stty erase '^H' 2>/dev/null
touch sbyg_update
fi
if [[ $vi = openvz ]]; then
cfargo_ym(){
tls=$(sed 's://.*::g' /etc/s-box/sb.json | jq -r '.inbounds[1].tls.enabled')
if [[ "$tls" = "false" ]]; then
echo "argo allowed"
else
yellow "因vmess开启了tls，Argo隧道功能不可用" && sleep 2
fi
}
"""

class PatchTests(unittest.TestCase):
    def test_expected_repairs_are_inserted(self):
        patched, changed = mod.patch_text(FIXTURE)
        self.assertTrue(changed)
        self.assertIn("if [[ -t 0 && -t 1 ]]; then", patched)
        self.assertIn("RUNTIME DEPENDENCY SELF-HEAL", patched)
        self.assertIn("command -v jq", patched)
        self.assertIn("jq -r '.inbounds[1].tls.enabled // empty'", patched)
        self.assertIn('if [[ "$tls" = "false" ]]; then', patched)

    def test_patch_is_idempotent(self):
        patched, changed = mod.patch_text(FIXTURE)
        patched2, changed2 = mod.patch_text(patched)
        self.assertTrue(changed)
        self.assertFalse(changed2)
        self.assertEqual(patched, patched2)

    def test_unknown_source_is_rejected(self):
        with self.assertRaises(RuntimeError):
            mod.patch_text("#!/bin/bash\\necho not the upstream source\\n")

if __name__ == "__main__":
    unittest.main()
