#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "resolve-package-policy.py"
SPEC = importlib.util.spec_from_file_location("resolve_package_policy", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
resolver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(resolver)

RELEASED = {"help", "status", "create-threat-model"}
WITH_BRANCH_SKILL = RELEASED | {"security-score"}


def policy(include: list[str], optional: list[str] | None = None) -> dict:
    data: dict = {"plugin_surface": {"skills": {"include": list(include)}}}
    if optional is not None:
        data["optional_skills"] = optional
    return data


class ResolveOptionalSkillsTests(unittest.TestCase):
    def test_optional_skill_present_in_ref_is_included(self) -> None:
        resolved, kept, dropped = resolver.resolve(
            policy(["help", "status"], ["security-score"]), WITH_BRANCH_SKILL
        )
        self.assertEqual(resolved["plugin_surface"]["skills"]["include"], ["help", "status", "security-score"])
        self.assertEqual((kept, dropped), (["security-score"], []))

    def test_optional_skill_absent_from_ref_is_skipped(self) -> None:
        resolved, kept, dropped = resolver.resolve(
            policy(["help", "status"], ["security-score"]), RELEASED
        )
        self.assertEqual(resolved["plugin_surface"]["skills"]["include"], ["help", "status"])
        self.assertEqual((kept, dropped), ([], ["security-score"]))

    def test_optional_skills_key_is_removed_from_the_resolved_policy(self) -> None:
        resolved, _, _ = resolver.resolve(policy(["help"], ["security-score"]), WITH_BRANCH_SKILL)
        self.assertNotIn("optional_skills", resolved)

    def test_source_policy_is_not_mutated(self) -> None:
        source = policy(["help"], ["security-score"])
        resolver.resolve(source, WITH_BRANCH_SKILL)
        self.assertEqual(source["plugin_surface"]["skills"]["include"], ["help"])
        self.assertEqual(source["optional_skills"], ["security-score"])

    def test_policy_without_optional_skills_is_unchanged(self) -> None:
        resolved, kept, dropped = resolver.resolve(policy(["help"]), WITH_BRANCH_SKILL)
        self.assertEqual(resolved, policy(["help"]))
        self.assertEqual((kept, dropped), ([], []))

    def test_unknown_skill_stays_a_hard_error_under_plugin_surface(self) -> None:
        # The allowlist proper keeps the strict upstream check; only names under
        # optional_skills are allowed to be absent. This resolver must not move
        # an unknown include entry out of the packager's way.
        resolved, _, _ = resolver.resolve(policy(["help", "typo-skill"]), RELEASED)
        self.assertIn("typo-skill", resolved["plugin_surface"]["skills"]["include"])


class ResolveRejectsUnsafePolicyTests(unittest.TestCase):
    def assert_rejected(self, data: dict, available: set[str], fragment: str) -> None:
        with self.assertRaises(resolver.PolicyResolutionError) as raised:
            resolver.resolve(data, available)
        self.assertIn(fragment, str(raised.exception))

    def test_name_in_both_lists_is_rejected(self) -> None:
        self.assert_rejected(
            policy(["help", "security-score"], ["security-score"]), WITH_BRANCH_SKILL, "keep it in one of them"
        )

    def test_duplicate_optional_name_is_rejected(self) -> None:
        self.assert_rejected(
            policy(["help"], ["security-score", "security-score"]), WITH_BRANCH_SKILL, "duplicates"
        )

    def test_path_traversal_in_an_optional_name_is_rejected(self) -> None:
        self.assert_rejected(policy(["help"], ["../../etc/passwd"]), RELEASED, "invalid skill name")

    def test_non_list_optional_skills_is_rejected(self) -> None:
        data = policy(["help"])
        data["optional_skills"] = "security-score"
        self.assert_rejected(data, WITH_BRANCH_SKILL, "must be a list of strings")

    def test_optional_skills_without_an_include_list_is_rejected(self) -> None:
        data = {"plugin_surface": {"skills": {"exclude": ["status"]}}, "optional_skills": ["security-score"]}
        self.assert_rejected(data, WITH_BRANCH_SKILL, "requires plugin_surface.skills.include")

    def test_optional_skills_without_a_plugin_surface_is_rejected(self) -> None:
        self.assert_rejected(
            {"optional_skills": ["security-score"]}, WITH_BRANCH_SKILL, "requires a plugin_surface"
        )


class UpstreamSkillDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "upstream"
        (self.source / "scripts").mkdir(parents=True)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_packager(self, body: str) -> None:
        (self.source / "scripts" / "package_internal_plugin.py").write_text(body, encoding="utf-8")

    def test_ids_come_from_the_selected_upstream_packager(self) -> None:
        self.write_packager(
            "from pathlib import Path\n"
            "def _available_skills(source: Path):\n"
            "    return {'help', 'security-score'}\n"
        )
        self.assertEqual(resolver.upstream_skill_ids(self.source), {"help", "security-score"})

    def test_missing_packager_fails_closed(self) -> None:
        with self.assertRaises(resolver.PolicyResolutionError) as raised:
            resolver.upstream_skill_ids(self.source)
        self.assertIn("has no packager", str(raised.exception))

    def test_packager_without_skill_discovery_fails_closed(self) -> None:
        self.write_packager("def unrelated():\n    return None\n")
        with self.assertRaises(resolver.PolicyResolutionError) as raised:
            resolver.upstream_skill_ids(self.source)
        self.assertIn("does not expose skill discovery", str(raised.exception))

    def test_invalid_skill_id_set_fails_closed(self) -> None:
        self.write_packager(
            "from pathlib import Path\n"
            "def _available_skills(source: Path):\n"
            "    return ['help']\n"
        )
        with self.assertRaises(resolver.PolicyResolutionError) as raised:
            resolver.upstream_skill_ids(self.source)
        self.assertIn("invalid skill-id set", str(raised.exception))


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "upstream"
        (self.source / "scripts").mkdir(parents=True)
        (self.source / "scripts" / "package_internal_plugin.py").write_text(
            "from pathlib import Path\n"
            "def _available_skills(source: Path):\n"
            "    return {'help', 'security-score'}\n",
            encoding="utf-8",
        )
        self.policy = self.root / "package-policy.yaml"
        self.out = self.root / "resolved.yaml"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _main(self) -> int:
        argv = sys.argv
        sys.argv = [
            "resolve-package-policy.py",
            "--source",
            str(self.source),
            "--policy",
            str(self.policy),
            "--out",
            str(self.out),
        ]
        try:
            return resolver.main()
        finally:
            sys.argv = argv

    def test_resolved_policy_is_written_and_the_source_file_untouched(self) -> None:
        original = "plugin_surface:\n  skills:\n    include:\n      - help\noptional_skills:\n  - security-score\n"
        self.policy.write_text(original, encoding="utf-8")
        self.assertEqual(self._main(), 0)
        written = yaml.safe_load(self.out.read_text(encoding="utf-8"))
        self.assertEqual(written["plugin_surface"]["skills"]["include"], ["help", "security-score"])
        self.assertNotIn("optional_skills", written)
        self.assertEqual(self.policy.read_text(encoding="utf-8"), original)

    def test_unreadable_policy_exits_two_without_writing_output(self) -> None:
        self.assertEqual(self._main(), 2)
        self.assertFalse(self.out.exists())

    def test_invalid_policy_exits_two_without_writing_output(self) -> None:
        self.policy.write_text("plugin_surface: [\n", encoding="utf-8")
        self.assertEqual(self._main(), 2)
        self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()
