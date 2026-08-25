#!/usr/bin/env python3
"""Tests for strict SemVer selection of the latest upstream release tag."""

from pathlib import Path
import subprocess
import sys
import unittest


SELECTOR = Path(__file__).parents[1] / "scripts" / "select-latest-release.py"


class SelectLatestReleaseTests(unittest.TestCase):
    def select(self, *tags: str) -> str:
        result = subprocess.run(
            [sys.executable, str(SELECTOR)],
            input="".join(f"abc123\trefs/tags/{tag}\n" for tag in tags),
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout.strip()

    def test_release_has_higher_precedence_than_its_prerelease(self) -> None:
        self.assertEqual(self.select("v0.6.0-beta.1", "v0.6.0"), "v0.6.0")

    def test_prerelease_identifiers_follow_semver_precedence(self) -> None:
        self.assertEqual(
            self.select("v1.0.0-beta.2", "v1.0.0-beta.10", "v1.0.0-rc.1"),
            "v1.0.0-rc.1",
        )

    def test_invalid_or_non_semver_tags_are_ignored(self) -> None:
        self.assertEqual(
            self.select("release-9", "v01.0.0", "v1.0.0-01", "v2$(shell,id)", "v1.2.3"),
            "v1.2.3",
        )

    def test_no_valid_release_produces_no_output(self) -> None:
        self.assertEqual(self.select("dev", "v1", "v1.0"), "")


if __name__ == "__main__":
    unittest.main()
