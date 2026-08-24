#!/usr/bin/env python3
"""Tests for removing inactive session-banner code from packages."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "prune-packaged-session-banner.py"
SPEC = importlib.util.spec_from_file_location("prune_packaged_session_banner", SCRIPT)
assert SPEC and SPEC.loader
pruner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pruner)


class PrunePackagedSessionBannerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "plugin"
        (self.root / ".claude-plugin").mkdir(parents=True)
        (self.root / "hooks").mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "scripts" / "session_banner.py").write_text("pass\n", encoding="utf-8")
        (self.root / "hooks" / "hooks.json").write_text(
            json.dumps({"hooks": {}}), encoding="utf-8"
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_surface(self, included: list[str]) -> None:
        (self.root / ".claude-plugin" / "package-surface.json").write_text(
            json.dumps({"hooks": {"included": included}}), encoding="utf-8"
        )

    def test_removes_script_when_hook_is_not_in_surface(self) -> None:
        self.write_surface([])
        self.assertTrue(pruner.prune(self.root))
        self.assertFalse((self.root / "scripts" / "session_banner.py").exists())

    def test_keeps_script_when_hook_is_in_surface(self) -> None:
        self.write_surface(["session-banner"])
        self.assertFalse(pruner.prune(self.root))
        self.assertTrue((self.root / "scripts" / "session_banner.py").is_file())

    def test_fails_closed_when_hook_registration_disagrees(self) -> None:
        self.write_surface([])
        (self.root / "hooks" / "hooks.json").write_text(
            json.dumps(
                {
                    "hooks": {
                        "SessionStart": [
                            {"hooks": [{"command": "python3 scripts/session_banner.py"}]}
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(pruner.SessionBannerPruneError, "still registers"):
            pruner.prune(self.root)
        self.assertTrue((self.root / "scripts" / "session_banner.py").is_file())


if __name__ == "__main__":
    unittest.main()
