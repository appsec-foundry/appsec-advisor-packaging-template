#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-org-hook-collisions.py"
SPEC = importlib.util.spec_from_file_location("check_org_hook_collisions", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class HookCollisionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "upstream"
        (self.source / "scripts").mkdir(parents=True)
        (self.source / "hooks").mkdir()
        (self.source / "scripts" / "package_internal_plugin.py").write_text(
            "from pathlib import Path\n"
            "def _available_hook_ids(source: Path):\n"
            "    return {'agent-logger', 'session-banner', 'skill-policy-gate'}\n",
            encoding="utf-8",
        )
        self.profile = self.root / "org-profile.yaml"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_profile(self, hook_id: str | None) -> None:
        hooks = "hooks: {}\n" if hook_id is None else f"hooks:\n  {hook_id}: {{}}\n"
        self.profile.write_text(f"organization:\n  id: acme\n{hooks}", encoding="utf-8")

    def test_distinct_org_hook_is_allowed(self) -> None:
        self.write_profile("org-block-risky-bash")
        self.assertEqual(checker.check(self.source, self.profile), set())

    def test_upstream_collision_is_rejected_with_replacement_guidance(self) -> None:
        self.write_profile("session-banner")
        with self.assertRaises(checker.HookCollisionError) as raised:
            checker.check(self.source, self.profile)
        message = str(raised.exception)
        self.assertIn("session-banner", message)
        self.assertIn("organization-prefixed id", message)
        self.assertIn("plugin_surface.hooks.include", message)

    def test_all_collisions_are_reported_deterministically(self) -> None:
        self.profile.write_text(
            "hooks:\n  skill-policy-gate: {}\n  agent-logger: {}\n",
            encoding="utf-8",
        )
        with self.assertRaises(checker.HookCollisionError) as raised:
            checker.check(self.source, self.profile)
        self.assertIn("agent-logger, skill-policy-gate", str(raised.exception))

    def test_no_org_hooks_is_allowed(self) -> None:
        self.write_profile(None)
        self.assertEqual(checker.check(self.source, self.profile), set())

    def test_invalid_yaml_fails_closed(self) -> None:
        self.profile.write_text("hooks: [\n", encoding="utf-8")
        with self.assertRaises(checker.HookCollisionError):
            checker.check(self.source, self.profile)

    def test_invalid_upstream_hook_discovery_fails_closed(self) -> None:
        (self.source / "scripts" / "package_internal_plugin.py").write_text(
            "def unrelated():\n    return None\n",
            encoding="utf-8",
        )
        self.write_profile("acme-hook")
        with self.assertRaises(checker.HookCollisionError) as raised:
            checker.check(self.source, self.profile)
        self.assertIn("does not expose hook-id discovery", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
