#!/usr/bin/env python3
"""Tests for composing the vendored baseline with an optional org overlay."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "compose-baseline.py"
SPEC = importlib.util.spec_from_file_location("compose_baseline", SCRIPT)
assert SPEC and SPEC.loader
composer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(composer)


class ComposeBaselineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.org_profile = Path(self.temporary.name)
        (self.org_profile / "baselines").mkdir()
        (self.org_profile / "org-profile.yaml").write_text(
            "baseline:\n  file: baselines/secure-coding-baseline.md\n", encoding="utf-8"
        )
        self.base_path = self.org_profile / "baselines" / "secure-coding-baseline.md"
        self.base_path.write_text(
            "# Secure Coding Baseline\n\nbaseline-id: aiscb-0.1.10\n\nRULE-1: do the thing.\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_overlay(self, text: str) -> Path:
        overlay = self.org_profile / "baselines" / composer.OVERLAY_NAME
        overlay.write_text(text, encoding="utf-8")
        return overlay

    def test_no_overlay_is_a_no_op(self) -> None:
        original = self.base_path.read_text(encoding="utf-8")
        self.assertFalse(composer.compose(self.org_profile))
        self.assertEqual(self.base_path.read_text(encoding="utf-8"), original)

    def test_overlay_is_appended_and_keeps_a_single_id(self) -> None:
        self.write_overlay("## Organization rules\n\nORG-1: also do this.\n")
        self.assertTrue(composer.compose(self.org_profile))
        composed = self.base_path.read_text(encoding="utf-8")
        self.assertIn("RULE-1: do the thing.", composed)
        self.assertIn("ORG-1: also do this.", composed)
        self.assertEqual(len(composer.MARKER_PATTERN.findall(composed)), 1)

    def test_overlay_with_its_own_id_marker_is_rejected(self) -> None:
        self.write_overlay("baseline-id: acme-0.1\n\nORG-1: also do this.\n")
        with self.assertRaisesRegex(composer.ComposeError, "exactly one baseline-id marker"):
            composer.compose(self.org_profile)
        # Rejected compositions must not leave a partially written base file.
        self.assertNotIn("ORG-1", self.base_path.read_text(encoding="utf-8"))

    def test_baseline_file_defaults_when_profile_omits_it(self) -> None:
        (self.org_profile / "org-profile.yaml").write_text("{}\n", encoding="utf-8")
        self.write_overlay("ORG-1: also do this.\n")
        self.assertTrue(composer.compose(self.org_profile))
        self.assertIn("ORG-1", self.base_path.read_text(encoding="utf-8"))

    def test_main_reports_a_composition_error_as_exit_two(self) -> None:
        self.write_overlay("baseline-id: acme-0.1\n\nORG-1: also do this.\n")
        argv = sys.argv
        sys.argv = ["compose-baseline.py", "--org-profile", str(self.org_profile)]
        try:
            self.assertEqual(composer.main(), 2)
        finally:
            sys.argv = argv


if __name__ == "__main__":
    unittest.main()
