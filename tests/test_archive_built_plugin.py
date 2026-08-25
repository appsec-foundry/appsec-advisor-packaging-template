#!/usr/bin/env python3
"""Focused failure-boundary tests for packaged plugin archives."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


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
            zip_path = dist / "acme-appsec-1.2.3.zip"
            zip_sha_path = dist / "acme-appsec-1.2.3.zip.sha256"
            unrelated = dist / "acme-appsec-1.2.4.tgz"
            tar_path.write_text("stale", encoding="utf-8")
            sha_path.symlink_to(tar_path.name)
            zip_path.write_text("stale", encoding="utf-8")
            zip_sha_path.write_text("stale", encoding="utf-8")
            unrelated.write_text("keep", encoding="utf-8")

            archiver.remove_stale_archive("acme-appsec", "1.2.3", dist)

            self.assertFalse(tar_path.exists())
            self.assertFalse(sha_path.exists())
            self.assertFalse(zip_path.exists())
            self.assertFalse(zip_sha_path.exists())
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
            script = root / "scripts" / "run.sh"
            script.parent.mkdir()
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            script.chmod(0o755)

            tar_path, sha_path = archiver.archive_plugin(root, Path(temporary) / "dist")

            self.assertEqual(tar_path.name, "acme-appsec-2.0.0.tgz")
            self.assertEqual(sha_path.name, "acme-appsec-2.0.0.tgz.sha256")
            self.assertIn(tar_path.name, sha_path.read_text(encoding="utf-8"))
            zip_path = tar_path.with_suffix(".zip")
            zip_sha_path = Path(f"{zip_path}.sha256")
            zip_digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
            self.assertEqual(
                zip_sha_path.read_text(encoding="utf-8"),
                f"{zip_digest}  {zip_path.name}\n",
            )
            with zipfile.ZipFile(zip_path) as archive:
                self.assertIn(
                    "acme-appsec/.claude-plugin/plugin.json", archive.namelist()
                )
                mode = archive.getinfo("acme-appsec/scripts/run.sh").external_attr >> 16
                self.assertEqual(mode & 0o777, 0o755)

    def test_zip_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "plugin"
            manifest = root / ".claude-plugin" / "plugin.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                json.dumps({"name": "acme-appsec", "version": "2.0.0"}),
                encoding="utf-8",
            )
            outside = Path(temporary) / "outside.txt"
            outside.write_text("outside", encoding="utf-8")
            (root / "outside.txt").symlink_to(outside)

            with self.assertRaisesRegex(archiver.ArchiveError, "symlink"):
                archiver.archive_plugin(root, Path(temporary) / "dist")


if __name__ == "__main__":
    unittest.main()
