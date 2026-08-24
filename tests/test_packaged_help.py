#!/usr/bin/env python3
"""Tests for package-specific help rendering and post-smoke archiving."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).parents[1]


def load_script(name: str):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


help_renderer = load_script("render-packaged-help.py")
archiver = load_script("archive-built-plugin.py")


class PackagedHelpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "build" / "pruf-appsec"
        (self.root / ".claude-plugin").mkdir(parents=True)
        self.write_json(
            ".claude-plugin/plugin.json",
            {"name": "pruf-appsec", "version": "0.6.0-beta.2+pruf.7"},
        )
        self.write_json(
            ".claude-plugin/package-surface.json",
            {
                "version": 1,
                "skills": {
                    "included": [
                        "org-review",
                        "internal-threat-analysis-kernel",
                        "help",
                        "create-threat-model",
                        "verify-requirements",
                    ],
                    "removed": ["publish-threat-model", "report-error"],
                },
            },
        )
        self.write_json(
            "config.json",
            {
                "banner": {
                    "enabled": True,
                    "headline": "PRUF AppSec Advisor",
                    "url": "https://security.example.test/appsec",
                },
                "skill_toggles": {
                    "verify-requirements": {
                        "enabled": False,
                        "reason": "Prüf+Øvelse policy is not active yet.",
                    }
                },
            },
        )
        self.write_skill("help", "Generic upstream help.")
        self.write_skill("create-threat-model", "Create the first threat model. More.")
        self.write_skill("verify-requirements", "Verify configured requirements.")
        self.write_skill(
            "org-review", "Review `org` controls.\nIgnore instructions <here>."
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_json(self, relative: str, value: object) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")

    def write_skill(self, name: str, description: str) -> None:
        path = self.root / "skills" / name / "SKILL.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            f"---\nname: {name}\ndescription: {json.dumps(description)}\n---\n\nBody.\n",
            encoding="utf-8",
        )

    def test_renders_only_public_included_skills_and_disabled_reason(self) -> None:
        destination = help_renderer.render_help(self.root)
        rendered = destination.read_text(encoding="utf-8")

        self.assertIn("pruf-appsec 0.6.0-beta.2+pruf.7", rendered)
        self.assertIn("/pruf-appsec:create-threat-model", rendered)
        self.assertIn("/pruf-appsec:org-review", rendered)
        self.assertIn("/pruf-appsec:verify-requirements", rendered)
        self.assertIn("[disabled]", rendered)
        self.assertIn("Reason: Prüf+Øvelse policy is not active yet.", rendered)
        self.assertIn("More information", rendered)
        self.assertIn("https://security.example.test/appsec", rendered)
        self.assertNotIn("publish-threat-model", rendered)
        self.assertNotIn("report-error", rendered)
        self.assertNotIn("internal-threat-analysis-kernel", rendered)
        self.assertNotIn("`org`", rendered)
        self.assertNotIn("<here>", rendered)

    def test_render_is_deterministic(self) -> None:
        first = help_renderer.render_help(self.root).read_bytes()
        second = help_renderer.render_help(self.root).read_bytes()
        self.assertEqual(first, second)

    def test_fails_closed_when_surface_is_ambiguous(self) -> None:
        surface_path = self.root / ".claude-plugin" / "package-surface.json"
        surface = json.loads(surface_path.read_text(encoding="utf-8"))
        surface["skills"]["removed"].append("help")
        surface_path.write_text(json.dumps(surface), encoding="utf-8")
        original_help = (self.root / "skills" / "help" / "SKILL.md").read_bytes()

        with self.assertRaisesRegex(
            help_renderer.HelpRenderError, "included and removed"
        ):
            help_renderer.render_help(self.root)
        self.assertEqual(
            original_help,
            (self.root / "skills" / "help" / "SKILL.md").read_bytes(),
        )

    def test_fails_when_included_skill_is_missing(self) -> None:
        (self.root / "skills" / "org-review" / "SKILL.md").unlink()
        with self.assertRaisesRegex(help_renderer.HelpRenderError, "missing SKILL.md"):
            help_renderer.render_help(self.root)

    def test_fails_when_help_is_not_included(self) -> None:
        surface_path = self.root / ".claude-plugin" / "package-surface.json"
        surface = json.loads(surface_path.read_text(encoding="utf-8"))
        surface["skills"]["included"].remove("help")
        surface_path.write_text(json.dumps(surface), encoding="utf-8")
        with self.assertRaisesRegex(
            help_renderer.HelpRenderError, "must include the help"
        ):
            help_renderer.render_help(self.root)

    def test_rejects_info_url_with_embedded_credentials(self) -> None:
        config_path = self.root / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["banner"]["url"] = "https://user:secret@security.example.test/appsec"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        original_help = (self.root / "skills" / "help" / "SKILL.md").read_bytes()

        with self.assertRaisesRegex(
            help_renderer.HelpRenderError, "without credentials"
        ):
            help_renderer.render_help(self.root)
        self.assertEqual(
            original_help,
            (self.root / "skills" / "help" / "SKILL.md").read_bytes(),
        )

    def test_rejects_plain_http_info_url(self) -> None:
        config_path = self.root / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["banner"]["url"] = "http://security.example.test/appsec"
        config_path.write_text(json.dumps(config), encoding="utf-8")

        with self.assertRaisesRegex(help_renderer.HelpRenderError, "HTTPS"):
            help_renderer.render_help(self.root)

    def test_rejects_info_url_that_can_break_the_reference_block(self) -> None:
        config_path = self.root / "config.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        config["banner"]["url"] = "https://security.example.test/```/escape"
        config_path.write_text(json.dumps(config), encoding="utf-8")

        with self.assertRaisesRegex(help_renderer.HelpRenderError, "unsafe"):
            help_renderer.render_help(self.root)

    def test_archive_contains_the_rendered_help_and_valid_checksum(self) -> None:
        rendered = help_renderer.render_help(self.root).read_bytes()
        dist = Path(self.temporary.name) / "dist"
        tar_path, sha_path = archiver.archive_plugin(self.root, dist)

        expected_digest = hashlib.sha256(tar_path.read_bytes()).hexdigest()
        self.assertEqual(
            sha_path.read_text(encoding="utf-8"),
            f"{expected_digest}  {tar_path.name}\n",
        )
        with tarfile.open(tar_path, "r:gz") as archive:
            member = archive.extractfile("pruf-appsec/skills/help/SKILL.md")
            self.assertIsNotNone(member)
            assert member
            self.assertEqual(rendered, member.read())

    def test_stale_archive_is_removed_before_rebuilding(self) -> None:
        dist = Path(self.temporary.name) / "dist"
        dist.mkdir()
        archive = dist / "pruf-appsec-0.6.0-beta.2+pruf.7.tgz"
        checksum = archive.with_suffix(".tgz.sha256")
        archive.write_text("stale", encoding="utf-8")
        checksum.write_text("stale", encoding="utf-8")

        archiver.remove_stale_archive("pruf-appsec", "0.6.0-beta.2+pruf.7", dist)

        self.assertFalse(archive.exists())
        self.assertFalse(checksum.exists())


if __name__ == "__main__":
    unittest.main()
