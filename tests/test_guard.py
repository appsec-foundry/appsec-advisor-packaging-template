#!/usr/bin/env python3
"""Behavior tests for the example PreToolUse Bash hook."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
from unittest import mock
import unittest


GUARD_PATH = Path(__file__).parents[1] / "org-profile" / "hooks" / "guard.py"
SPEC = importlib.util.spec_from_file_location("guard", GUARD_PATH)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class GuardTests(unittest.TestCase):
    def run_hook(self, event: str) -> str:
        output = io.StringIO()
        with mock.patch.object(guard.sys, "stdin", io.StringIO(event)):
            with contextlib.redirect_stdout(output):
                self.assertEqual(guard.main(), 0)
        return output.getvalue()

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

    def test_hook_denies_risky_bash_with_claude_hook_schema(self) -> None:
        output = self.run_hook(
            json.dumps(
                {
                    "tool_name": "Bash",
                    "tool_input": {"command": "git reset --hard HEAD~1"},
                }
            )
        )
        decision = json.loads(output)
        hook_output = decision["hookSpecificOutput"]
        self.assertEqual(hook_output["hookEventName"], "PreToolUse")
        self.assertEqual(hook_output["permissionDecision"], "deny")
        self.assertIn("destructive Git", hook_output["permissionDecisionReason"])

    def test_hook_ignores_malformed_or_irrelevant_events(self) -> None:
        for event in (
            "not-json",
            json.dumps({"tool_name": "Read"}),
            json.dumps({"tool_name": "Bash", "tool_input": {"command": 123}}),
            json.dumps(
                {"tool_name": "Bash", "tool_input": {"command": "git status"}}
            ),
        ):
            with self.subTest(event=event):
                self.assertEqual(self.run_hook(event), "")


if __name__ == "__main__":
    unittest.main()
