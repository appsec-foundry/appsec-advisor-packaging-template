#!/usr/bin/env python3
"""Focused failure-boundary tests for packaged plugin archives."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts" / "archive-built-plugin.py"
SPEC = importlib.util.spec_from_file_location("archive_built_plugin", SCRIPT)
assert SPEC and SPEC.loader
archiver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(archiver)


class ArchiveBuiltPluginTests(unittest.TestCase):
    def test_rejects_missing_or_non_object_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "plugin"
            dist = Path(temporary) / "dist"
            with self.assertRaisesRegex(archiver.ArchiveError, "cannot read"):
                archiver.archive_plugin(root, dist)

            manifest = root / ".claude-plugin" / "plugin.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("[]\n", encoding="utf-8")
            with self.assertRaisesRegex(archiver.ArchiveError, "must be an object"):
                archiver.archive_plugin(root, dist)

    def test_rejects_unsafe_archive_identity(self) -> None:
        for name, version in (
            ("../escape", "1.0.0"),
            ("acme-appsec", "../1.0.0"),
            (None, "1.0.0"),
        ):
            with self.subTest(name=name, version=version):
                with self.assertRaises(archiver.ArchiveError):
                    archiver._validate_identity(name, version)

    def test_clean_removes_only_matching_archive_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            dist = Path(temporary)
            tar_path = dist / "acme-appsec-1.2.3.tgz"
            sha_path = dist / "acme-appsec-1.2.3.tgz.sha256"
            unrelated = dist / "acme-appsec-1.2.4.tgz"
            tar_path.write_text("stale", encoding="utf-8")
            sha_path.symlink_to(tar_path.name)
            unrelated.write_text("keep", encoding="utf-8")

            archiver.remove_stale_archive("acme-appsec", "1.2.3", dist)

            self.assertFalse(tar_path.exists())
            self.assertFalse(sha_path.exists())
            self.assertTrue(unrelated.is_file())

    def test_archive_uses_manifest_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "source-directory-name-is-ignored"
            manifest = root / ".claude-plugin" / "plugin.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                json.dumps({"name": "acme-appsec", "version": "2.0.0"}),
                encoding="utf-8",
            )

            tar_path, sha_path = archiver.archive_plugin(
                root, Path(temporary) / "dist"
            )

            self.assertEqual(tar_path.name, "acme-appsec-2.0.0.tgz")
            self.assertEqual(sha_path.name, "acme-appsec-2.0.0.tgz.sha256")
            self.assertIn(tar_path.name, sha_path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
