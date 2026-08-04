#!/usr/bin/env python3
"""Behavior tests for the example PreToolUse Bash hook."""

import importlib.util
from pathlib import Path
import unittest


GUARD_PATH = Path(__file__).parents[1] / "org-profile" / "hooks" / "guard.py"
SPEC = importlib.util.spec_from_file_location("guard", GUARD_PATH)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class GuardTests(unittest.TestCase):
    def test_blocks_destructive_commands(self) -> None:
        for command in (
            "rm -rf /tmp/build",
            "rm -r -f /tmp/build",
            "git reset --hard HEAD~1",
            "git clean -fd",
            "sudo systemctl restart production",
            "mkfs.ext4 /dev/sdb",
            "dd if=/dev/zero of=/dev/sda",
            "shutdown now",
        ):
            with self.subTest(command=command):
                self.assertIsNotNone(guard.blocked_reason(command))

    def test_allows_normal_and_explanatory_commands(self) -> None:
        for command in (
            "git status",
            "rm generated-report.txt",
            "echo 'rm -rf /tmp/build'",
            "python3 -m pytest",
        ):
            with self.subTest(command=command):
                self.assertIsNone(guard.blocked_reason(command))


if __name__ == "__main__":
    unittest.main()
