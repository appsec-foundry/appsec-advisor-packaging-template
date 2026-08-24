#!/usr/bin/env python3
"""Tests for the read-only baseline upstream drift check."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "baseline-upstream-check.py"
SPEC = importlib.util.spec_from_file_location("baseline_upstream_check", SCRIPT)
assert SPEC and SPEC.loader
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class BaselineUpstreamCheckTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.profile = self.root / "org-profile.yaml"
        self.core = self.root / "config.json"
        self.document = self.root / "baseline.md"
        self.profile.write_text(
            "organization:\n  id: acme\npolicy:\n  url_allowlist:\n    - raw.githubusercontent.com\n",
            encoding="utf-8",
        )
        self.core.write_text(
            json.dumps(
                {
                    "baseline": {
                        "enabled": True,
                        "id": "aisec-0.1.7",
                        "url": checker.CURRENT_BASELINE_URL,
                    }
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_matching_published_marker_is_current(self) -> None:
        self.document.write_text("# Baseline\n\n`baseline-id: aisec-0.1.7` — rules\n", encoding="utf-8")
        self.assertEqual(
            checker.check(self.profile, self.core, document_path=self.document), 0
        )

    def test_new_published_marker_reports_drift(self) -> None:
        self.document.write_text("baseline-id: aisec-0.1.8\n", encoding="utf-8")
        self.assertEqual(
            checker.check(self.profile, self.core, document_path=self.document), 1
        )

    def test_disabled_baseline_skips_without_reading_document(self) -> None:
        self.profile.write_text("baseline:\n  enabled: false\n", encoding="utf-8")
        self.assertEqual(checker.check(self.profile, self.core), 0)

    def test_profile_source_and_id_replace_core_values(self) -> None:
        self.profile.write_text(
            "baseline:\n"
            "  id: acme-sec-2.0\n"
            "  url: https://security.example.test/baseline.md\n",
            encoding="utf-8",
        )
        self.document.write_text("baseline-id: acme-sec-2.0\n", encoding="utf-8")
        self.assertEqual(
            checker.check(self.profile, self.core, document_path=self.document), 0
        )

    def test_ambiguous_marker_is_an_error(self) -> None:
        self.document.write_text(
            "baseline-id: aisec-0.1.7\nbaseline-id: aisec-0.1.8\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(checker.BaselineCheckError, "exactly one"):
            checker.check(self.profile, self.core, document_path=self.document)

    def test_remote_check_rejects_plain_http_before_fetching(self) -> None:
        with self.assertRaisesRegex(checker.BaselineCheckError, "HTTPS"):
            checker._fetch("http://security.example.test/baseline.md", {}, self.core)


if __name__ == "__main__":
    unittest.main()
