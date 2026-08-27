#!/usr/bin/env python3
"""Tests for reading the published baseline id the initializer pins."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "resolve-baseline-id.py"
SPEC = importlib.util.spec_from_file_location("resolve_baseline_id", SCRIPT)
assert SPEC and SPEC.loader
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)


class ResolveBaselineIdTests(unittest.TestCase):
    def test_reads_the_marker_whatever_sentence_follows_it(self) -> None:
        for line, expected in (
            ("`baseline-id: aisec-0.1.8`. When asked whether a baseline is loaded.", "aisec-0.1.8"),
            ("`baseline-id: aisec-0.1` — when asked whether a baseline is loaded", "aisec-0.1"),
            ("baseline-id: aisec-0.2", "aisec-0.2"),
            ("`baseline-id: aisec-0.1.8+acme`.", "aisec-0.1.8+acme"),
        ):
            with self.subTest(line=line):
                document = f"# AI Secure Coding Baseline\n\n{line}\n".encode("utf-8")
                self.assertEqual(resolver.marker(document, "test"), expected)

    def test_ambiguous_or_missing_marker_is_an_error(self) -> None:
        for document in (
            b"# Baseline\n\nNo marker at all.\n",
            b"baseline-id: aisec-0.1.7\nbaseline-id: aisec-0.1.8\n",
            "The line baseline-id: aisec-0.1.8 only mentions it.\n".encode("utf-8"),
        ):
            with self.subTest(document=document):
                with self.assertRaisesRegex(resolver.ResolveError, "exactly one"):
                    resolver.marker(document, "test")

    def test_oversized_or_undecodable_document_is_rejected(self) -> None:
        with self.assertRaisesRegex(resolver.ResolveError, "exceeds"):
            resolver.marker(b"x" * (resolver.MAX_FETCH_BYTES + 1), "test")
        with self.assertRaisesRegex(resolver.ResolveError, "not UTF-8"):
            resolver.marker(b"baseline-id: \xff\xfe\n", "test")

    def test_unsafe_source_is_rejected_before_fetching(self) -> None:
        with self.assertRaisesRegex(resolver.ResolveError, "HTTPS"):
            resolver.fetch("http://security.example.test/baseline.md")
        with self.assertRaisesRegex(resolver.ResolveError, "no credentials"):
            resolver.fetch("https://user:password@security.example.test/baseline.md")

    def test_default_source_is_the_appsec_foundry_baseline(self) -> None:
        self.assertEqual(
            resolver.BASELINE_URL,
            "https://raw.githubusercontent.com/appsec-foundry/"
            "ai-secure-coding-baseline/main/secure-coding-baseline.md",
        )


if __name__ == "__main__":
    unittest.main()
