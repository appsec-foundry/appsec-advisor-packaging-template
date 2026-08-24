#!/usr/bin/env python3
"""Unit tests for packaged GitHub-origin normalization."""

from __future__ import annotations

import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "rewrite-packaged-origins.py"
SPEC = importlib.util.spec_from_file_location("rewrite_packaged_origins", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


LEGACY_BASELINE_RAW = (
    "https://raw.githubusercontent.com/matthiasrohr/ai-secure-coding-baseline/"
    "main/secure-coding-baseline.md"
)
BASELINE_RAW = (
    "https://raw.githubusercontent.com/appsec-foundry/ai-secure-coding-baseline/"
    "main/secure-coding-baseline.md"
)


def write_package(root: Path, baseline_url: str) -> None:
    (root / "docs").mkdir(parents=True)
    (root / "config.json").write_text(
        json.dumps({"baseline": {"id": "aisec-0.1", "url": baseline_url}}),
        encoding="utf-8",
    )
    (root / "docs" / "origins.md").write_text(
        "\n".join(
            [
                "https://github.com/matthiasrohr/ai-secure-coding-baseline",
                "https://github.com/matthiasrohr/appsec-advisor",
                "https://github.com/matthiasrohr/appsec-advisor-packaging-template",
            ]
        ),
        encoding="utf-8",
    )


def test_verified_origins_are_normalized() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root, LEGACY_BASELINE_RAW)
        assert MODULE.rewrite(root) == 2

        config = json.loads((root / "config.json").read_text(encoding="utf-8"))
        assert config["baseline"]["url"] == BASELINE_RAW
        assert "org-profile/org-profile.yaml" in config["_comment"]
        assert "skill_toggles" in config["_comment"]
        assert "presets" in config["_comment"]
        assert "baseline" in config["_comment"]
        assert "MCP" in config["_comment"]
        assert ".claude-plugin/package-surface.json" in config["_comment"]
        assert "org-profile/package-policy.yaml" in config["_comment"]
        assert "README.md#configuration-map" in config["_comment"]
        documentation = (root / "docs" / "origins.md").read_text(encoding="utf-8")
        assert "https://github.com/appsec-foundry/ai-secure-coding-baseline" in documentation
        assert "https://github.com/appsec-foundry/appsec-advisor" in documentation
        assert "matthiasrohr" not in documentation


def test_organization_baseline_url_is_not_changed() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        custom_url = "https://security.example.test/baseline.md"
        write_package(root, custom_url)
        MODULE.rewrite(root)

        config = json.loads((root / "config.json").read_text(encoding="utf-8"))
        assert config["baseline"]["url"] == custom_url


def test_unknown_personal_origin_fails_before_writing() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root, LEGACY_BASELINE_RAW)
        unknown = root / "docs" / "unknown.md"
        unknown.write_text("https://github.com/matthiasrohr/unknown-project\n", encoding="utf-8")

        try:
            MODULE.rewrite(root)
        except MODULE.RewriteError:
            pass
        else:
            raise AssertionError("unknown personal origin was accepted")

        config = json.loads((root / "config.json").read_text(encoding="utf-8"))
        assert config["baseline"]["url"] == LEGACY_BASELINE_RAW


def test_symlink_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root, LEGACY_BASELINE_RAW)
        (root / "docs" / "linked.md").symlink_to(root / "docs" / "origins.md")

        try:
            MODULE.rewrite(root)
        except MODULE.RewriteError:
            pass
        else:
            raise AssertionError("packaged symlink was accepted")


if __name__ == "__main__":
    test_verified_origins_are_normalized()
    test_organization_baseline_url_is_not_changed()
    test_unknown_personal_origin_fails_before_writing()
    test_symlink_is_rejected()
    print("rewrite-packaged-origins tests: OK")
