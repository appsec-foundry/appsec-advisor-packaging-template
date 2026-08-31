#!/usr/bin/env python3
"""Unit tests for retargeting packaged plugin-directory fallbacks."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "rewrite-packaged-plugin-paths.py"
SPEC = importlib.util.spec_from_file_location("rewrite_packaged_plugin_paths", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


SKILL_FALLBACK = (
    "```bash\n"
    'if [ -z "$CLAUDE_PLUGIN_ROOT" ]; then\n'
    "  CLAUDE_PLUGIN_ROOT=$(find /root /home /opt -maxdepth 6 \\\n"
    '    -path "*/appsec-advisor/skills/status/SKILL.md" \\\n'
    "    2>/dev/null | head -1)\n"
    "fi\n"
    "```\n"
)
# The upstream name also appears where it must survive: repository links and
# example output that shows an upstream checkout.
UNRELATED = (
    "https://github.com/appsec-foundry/appsec-advisor\n"
    "Loaded   : plugin cache /home/you/appsec-advisor/.cache/requirements.yaml\n"
)


def write_package(root: Path) -> None:
    (root / "skills" / "status").mkdir(parents=True)
    (root / "skills" / "status" / "SKILL.md").write_text(
        SKILL_FALLBACK + UNRELATED, encoding="utf-8"
    )
    (root / "agents").mkdir()
    (root / "agents" / "appsec-context-resolver.md").write_text(
        '  -path "*/appsec-advisor/config.json" 2>/dev/null | head -1\n',
        encoding="utf-8",
    )


def test_globs_are_retargeted_to_the_internal_name() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root)
        assert MODULE.rewrite(root, "acme-appsec") == 2

        skill = (root / "skills" / "status" / "SKILL.md").read_text(encoding="utf-8")
        assert '-path "*/acme-appsec/skills/status/SKILL.md"' in skill
        assert "*/appsec-advisor/" not in skill
        assert UNRELATED in skill

        agent = (root / "agents" / "appsec-context-resolver.md").read_text(
            encoding="utf-8"
        )
        assert '-path "*/acme-appsec/config.json"' in agent


def test_upstream_name_needs_no_rewrite() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root)
        assert MODULE.rewrite(root, "appsec-advisor") == 0

        skill = (root / "skills" / "status" / "SKILL.md").read_text(encoding="utf-8")
        assert '-path "*/appsec-advisor/skills/status/SKILL.md"' in skill


def test_unmatched_glob_fails_before_writing() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root)
        # A quoting style the rewrite does not know must fail loudly instead of
        # shipping a fallback that silently keeps the upstream directory name.
        (root / "skills" / "status" / "SKILL.md").write_text(
            SKILL_FALLBACK.replace('"*/appsec-advisor/', "'*/appsec-advisor/"),
            encoding="utf-8",
        )

        try:
            MODULE.rewrite(root, "acme-appsec")
        except MODULE.RewriteError:
            pass
        else:
            raise AssertionError("unmatched upstream glob was accepted")

        agent = (root / "agents" / "appsec-context-resolver.md").read_text(
            encoding="utf-8"
        )
        assert '-path "*/appsec-advisor/config.json"' in agent


def test_symlink_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        write_package(root)
        (root / "agents" / "linked.md").symlink_to(
            root / "agents" / "appsec-context-resolver.md"
        )

        try:
            MODULE.rewrite(root, "acme-appsec")
        except MODULE.RewriteError:
            pass
        else:
            raise AssertionError("packaged symlink was accepted")


def test_missing_plugin_root_is_rejected() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        try:
            MODULE.rewrite(Path(temporary) / "absent", "acme-appsec")
        except MODULE.RewriteError:
            pass
        else:
            raise AssertionError("missing plugin root was accepted")


if __name__ == "__main__":
    test_globs_are_retargeted_to_the_internal_name()
    test_upstream_name_needs_no_rewrite()
    test_unmatched_glob_fails_before_writing()
    test_symlink_is_rejected()
    test_missing_plugin_root_is_rejected()
    print("rewrite-packaged-plugin-paths tests: OK")
