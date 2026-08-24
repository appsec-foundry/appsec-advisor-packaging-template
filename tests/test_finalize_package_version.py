#!/usr/bin/env python3
"""Unit tests for the organization/core version adapter."""

from __future__ import annotations

import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "finalize-package-version.py"
SPEC = importlib.util.spec_from_file_location("finalize_package_version", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


VALIDATOR = '''import json
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parent.parent


def _read_plugin_version() -> str:
    meta = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
    if not meta.exists():
        return "0.0.0"
    try:
        return json.loads(meta.read_text()).get("version", "0.0.0")
    except (json.JSONDecodeError, OSError):
        return "0.0.0"
'''


def plugin_tree(root: Path, validator: str = VALIDATOR) -> None:
    (root / ".claude-plugin").mkdir(parents=True)
    (root / "scripts").mkdir()
    (root / ".claude-plugin" / "plugin.json").write_text(
        json.dumps({"name": "pruf-appsec", "version": "0.6.0-beta.1"}),
        encoding="utf-8",
    )
    (root / "scripts" / "validate_org_profile.py").write_text(validator, encoding="utf-8")


def load_validator(path: Path):
    spec = importlib.util.spec_from_file_location("packaged_validator", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_visible_and_core_versions_are_separate() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        plugin_tree(root)
        MODULE.finalize(root, "3.4.0-internal.2", "0.6.0-beta.1")

        manifest = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
        assert manifest["version"] == "3.4.0-internal.2"
        assert manifest["appsec_advisor_core_version"] == "0.6.0-beta.1"
        validator = load_validator(root / "scripts" / "validate_org_profile.py")
        assert validator._read_plugin_version() == "0.6.0-beta.1"


def test_unknown_upstream_validator_fails_before_manifest_change() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        plugin_tree(root, "# changed upstream implementation\n")
        try:
            MODULE.finalize(root, "3.4.0", "0.6.0-beta.1")
        except MODULE.FinalizeError:
            pass
        else:
            raise AssertionError("changed upstream validator was accepted")

        manifest = json.loads((root / ".claude-plugin" / "plugin.json").read_text())
        assert manifest["version"] == "0.6.0-beta.1"
        assert "appsec_advisor_core_version" not in manifest


if __name__ == "__main__":
    test_visible_and_core_versions_are_separate()
    test_unknown_upstream_validator_fails_before_manifest_change()
    print("finalize-package-version tests: OK")
