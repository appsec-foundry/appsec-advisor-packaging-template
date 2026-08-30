#!/usr/bin/env python3
"""Tests for the read-only baseline upstream drift check."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


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

    def test_marker_is_read_whatever_sentence_follows_it(self) -> None:
        for line in (
            "`baseline-id: aisec-0.1.7`. When asked whether a baseline is loaded, answer.",
            "`baseline-id: aisec-0.1.7` — when asked whether a baseline is loaded",
            "baseline-id: aisec-0.1.7",
            "  `baseline-id: aisec-0.1.7`",
        ):
            with self.subTest(line=line):
                self.document.write_text(f"# Baseline\n\n{line}\n", encoding="utf-8")
                self.assertEqual(
                    checker.check(self.profile, self.core, document_path=self.document), 0
                )

    def test_prose_mention_is_not_a_marker(self) -> None:
        self.document.write_text(
            "The line baseline-id: aisec-0.1.7 is the marker this document carries.\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(checker.BaselineCheckError, "exactly one"):
            checker.check(self.profile, self.core, document_path=self.document)

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

    def test_remote_check_rejects_credentials_and_invalid_allowlist(self) -> None:
        with self.assertRaisesRegex(checker.BaselineCheckError, "no credentials"):
            checker._fetch(
                "https://user:password@security.example.test/baseline.md",
                {},
                self.core,
            )
        with self.assertRaisesRegex(checker.BaselineCheckError, "must contain host"):
            checker._profile_allowlist(
                {"policy": {"url_allowlist": ["raw.githubusercontent.com", 123]}}
            )

    def test_legacy_defaults_are_checked_against_the_current_source(self) -> None:
        self.assertEqual(len(checker.LEGACY_BASELINE_URLS), 2)
        for legacy in checker.LEGACY_BASELINE_URLS:
            with self.subTest(legacy=legacy):
                core = json.loads(self.core.read_text(encoding="utf-8"))
                core["baseline"]["url"] = legacy
                self.core.write_text(json.dumps(core), encoding="utf-8")
                document = b"baseline-id: aisec-0.1.7\n"
                with mock.patch.object(checker, "_fetch", return_value=document) as fetch:
                    self.assertEqual(checker.check(self.profile, self.core), 0)
                fetch.assert_called_once_with(
                    checker.CURRENT_BASELINE_URL, mock.ANY, self.core
                )

    def test_https_fetch_is_bounded_and_uses_the_url_guard(self) -> None:
        class Verdict:
            ok = True
            reason = ""

        guard = mock.Mock()
        guard.validate_target_url.return_value = Verdict()

        response = mock.MagicMock()
        response.headers = {"Content-Length": "31"}
        response.read.return_value = b"baseline-id: aisec-0.1.7\n"
        response.__enter__.return_value = response
        opener = mock.Mock()
        opener.open.return_value = response

        with mock.patch.object(checker, "_load_url_guard", return_value=guard):
            with mock.patch.object(
                checker.urllib.request, "build_opener", return_value=opener
            ):
                document = checker._fetch(
                    checker.CURRENT_BASELINE_URL,
                    {"policy": {"url_allowlist": ["raw.githubusercontent.com"]}},
                    self.core,
                )

        self.assertEqual(document, b"baseline-id: aisec-0.1.7\n")
        guard.validate_target_url.assert_called_once_with(
            checker.CURRENT_BASELINE_URL, check_ip_safety=False
        )
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, checker.CURRENT_BASELINE_URL)
        self.assertEqual(
            opener.open.call_args.kwargs["timeout"], checker.FETCH_TIMEOUT_SECONDS
        )
        response.read.assert_called_once_with(checker.MAX_FETCH_BYTES + 1)

    def test_redirect_handler_rejects_plain_http_and_blocked_targets(self) -> None:
        class Verdict:
            def __init__(self, ok: bool, reason: str = "") -> None:
                self.ok = ok
                self.reason = reason

        guard = mock.Mock()
        guard.validate_target_url.return_value = Verdict(True)
        response = mock.MagicMock()
        response.headers = {}
        response.read.return_value = b"baseline-id: aisec-0.1.7\n"
        response.__enter__.return_value = response
        opener = mock.Mock()
        opener.open.return_value = response

        with mock.patch.object(checker, "_load_url_guard", return_value=guard):
            with mock.patch.object(
                checker.urllib.request, "build_opener", return_value=opener
            ) as build_opener:
                checker._fetch(checker.CURRENT_BASELINE_URL, {}, self.core)

        handler = build_opener.call_args.args[0]
        with self.assertRaisesRegex(checker.urllib.error.HTTPError, "HTTPS"):
            handler.redirect_request(
                None, None, 302, "Found", {}, "http://example.test/baseline.md"
            )

        guard.validate_target_url.return_value = Verdict(False, "not allowlisted")
        with self.assertRaisesRegex(checker.urllib.error.HTTPError, "not allowlisted"):
            handler.redirect_request(
                None,
                None,
                302,
                "Found",
                {},
                "https://example.test/baseline.md",
            )

    def test_initial_url_guard_rejection_stops_before_network_open(self) -> None:
        class Verdict:
            ok = False
            reason = "not allowlisted"

        guard = mock.Mock()
        guard.validate_target_url.return_value = Verdict()
        with mock.patch.object(checker, "_load_url_guard", return_value=guard):
            with mock.patch.object(checker.urllib.request, "build_opener") as opener:
                with self.assertRaisesRegex(checker.BaselineCheckError, "blocked"):
                    checker._fetch(checker.CURRENT_BASELINE_URL, {}, self.core)
        opener.assert_not_called()

    def test_https_fetch_rejects_oversized_response_before_reading(self) -> None:
        class Verdict:
            ok = True
            reason = ""

        guard = mock.Mock()
        guard.validate_target_url.return_value = Verdict()
        response = mock.MagicMock()
        response.headers = {"Content-Length": str(checker.MAX_FETCH_BYTES + 1)}
        response.__enter__.return_value = response
        opener = mock.Mock()
        opener.open.return_value = response

        with mock.patch.object(checker, "_load_url_guard", return_value=guard):
            with mock.patch.object(
                checker.urllib.request, "build_opener", return_value=opener
            ):
                with self.assertRaisesRegex(checker.BaselineCheckError, "exceeds"):
                    checker._fetch(
                        checker.CURRENT_BASELINE_URL, {}, self.core
                    )
        response.read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
