#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_manager_source", ROOT / "tools" / "check_manager_source.py"
)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)


class ManagerSourceTests(unittest.TestCase):
    def test_exact_filename_in_root(self):
        tree = [{"type": "blob", "path": "sb-manager-debian-alpine.sh"}]
        self.assertEqual(
            mod.find_candidates(tree, "sb-manager-debian-alpine.sh"),
            ["sb-manager-debian-alpine.sh"],
        )

    def test_exact_filename_moved_to_subdirectory(self):
        tree = [{"type": "blob", "path": "scripts/sb-manager-debian-alpine.sh"}]
        self.assertEqual(
            mod.find_candidates(tree, "sb-manager-debian-alpine.sh"),
            ["scripts/sb-manager-debian-alpine.sh"],
        )

    def test_similar_manager_script_is_suggested(self):
        tree = [
            {"type": "blob", "path": "scripts/sb-manager-debian.sh"},
            {"type": "blob", "path": "README.md"},
        ]
        self.assertEqual(
            mod.find_candidates(tree, "sb-manager-debian-alpine.sh"),
            ["scripts/sb-manager-debian.sh"],
        )

    def test_non_script_files_are_ignored(self):
        tree = [{"type": "tree", "path": "sb-manager-debian-alpine.sh"}]
        self.assertEqual(mod.find_candidates(tree, "sb-manager-debian-alpine.sh"), [])

    def test_raw_url_encodes_ref_and_path(self):
        self.assertEqual(
            mod.raw_url("owner/repo", "release/v1", "scripts/a file.sh"),
            "https://raw.githubusercontent.com/owner/repo/release%2Fv1/scripts/a%20file.sh",
        )


if __name__ == "__main__":
    unittest.main()
