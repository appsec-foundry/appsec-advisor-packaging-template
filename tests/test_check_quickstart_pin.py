#!/usr/bin/env python3
"""Tests for the release-boundary check on the README quick-start pin."""

from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "check-quickstart-pin.py"
SPEC = importlib.util.spec_from_file_location("check_quickstart_pin", SCRIPT)
assert SPEC and SPEC.loader
pin = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pin)

COMMIT = "a" * 40
INITIALIZER_BODY = b"#!/usr/bin/env bash\necho scaffolding\n"


def _no_commit_lookup(repo, ref):  # noqa: ANN001, ARG001
    """Stand in for git: the suite puts a stub on PATH, so never call the real one."""
    return None


def _readme(ref: str, digest: str) -> str:
    return (
        "## Quick start\n\n"
        "```bash\n"
        "curl --proto '=https' \\\n"
        "  --output appsec-advisor-init.sh \\\n"
        f"  https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/{ref}"
        "/scripts/init-org-repo.sh &&\n"
        f"echo '{digest}  appsec-advisor-init.sh' |\n"
        "  sha256sum --check &&\n"
        "bash appsec-advisor-init.sh\n"
        "```\n"
    )


class QuickstartPinTests(unittest.TestCase):
    def _repo(self, *, readme: str, initializer: bytes = INITIALIZER_BODY) -> Path:
        root = Path(tempfile.mkdtemp())
        (root / "scripts").mkdir()
        (root / "README.md").write_text(readme, encoding="utf-8")
        (root / "scripts" / "init-org-repo.sh").write_bytes(initializer)
        return root

    def test_matching_checksum_passes(self) -> None:
        digest = hashlib.sha256(INITIALIZER_BODY).hexdigest()
        repo = self._repo(readme=_readme(COMMIT, digest))
        self.assertEqual(pin.check(repo, read_commit=_no_commit_lookup), 0)

    def test_stale_checksum_names_both_digests(self) -> None:
        repo = self._repo(readme=_readme(COMMIT, "0" * 64))
        with self.assertRaises(pin.PinError) as raised:
            pin.check(repo, read_commit=_no_commit_lookup)
        message = str(raised.exception)
        self.assertIn("0" * 64, message)
        self.assertIn(hashlib.sha256(INITIALIZER_BODY).hexdigest(), message)

    def test_a_branch_or_tag_is_not_an_immutable_pin(self) -> None:
        digest = hashlib.sha256(INITIALIZER_BODY).hexdigest()
        for ref in ("main", "v1.2.0"):
            with self.subTest(ref=ref):
                repo = self._repo(readme=_readme(ref, digest))
                with self.assertRaises(pin.PinError):
                    pin.check(repo, read_commit=_no_commit_lookup)

    def test_a_second_pin_is_ambiguous_rather_than_ignored(self) -> None:
        digest = hashlib.sha256(INITIALIZER_BODY).hexdigest()
        readme = _readme(COMMIT, digest) + _readme("b" * 40, digest)
        repo = self._repo(readme=readme)
        with self.assertRaises(pin.PinError):
            pin.check(repo, read_commit=_no_commit_lookup)

    def test_a_pinned_commit_with_other_bytes_is_rejected(self) -> None:
        digest = hashlib.sha256(INITIALIZER_BODY).hexdigest()
        repo = self._repo(readme=_readme(COMMIT, digest))
        with self.assertRaises(pin.PinError) as raised:
            pin.check(repo, read_commit=lambda _repo, _ref: b"an older initializer\n")
        self.assertIn(COMMIT, str(raised.exception))

    def test_a_pinned_commit_with_the_shipped_bytes_passes(self) -> None:
        digest = hashlib.sha256(INITIALIZER_BODY).hexdigest()
        repo = self._repo(readme=_readme(COMMIT, digest))
        self.assertEqual(pin.check(repo, read_commit=lambda _repo, _ref: INITIALIZER_BODY), 0)

    def test_the_shipped_repository_is_pinned_correctly(self) -> None:
        self.assertEqual(pin.check(ROOT, read_commit=_no_commit_lookup), 0)


if __name__ == "__main__":
    unittest.main()
