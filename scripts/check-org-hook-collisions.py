#!/usr/bin/env python3
"""Reject organization hook ids that collide with the selected upstream.

The upstream packager merges org hooks into hooks/hooks.json. A shared id would
make the package policy select both handlers together, which is neither a safe
override nor an unambiguous addition. Derive the ids through the selected
upstream packager itself so branch builds are checked against their current
hook surface rather than a stale list maintained by this template.
"""

from __future__ import annotations

import argparse
import importlib.util
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import yaml


class HookCollisionError(ValueError):
    """Raised when the hook customization cannot be checked safely."""


def _load_mapping(path: Path) -> dict[str, Any]:
    try:
        loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise HookCollisionError(f"cannot read organization profile {path}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise HookCollisionError(f"organization profile is not valid UTF-8: {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise HookCollisionError(f"organization profile is not valid YAML: {path}: {exc}") from exc
    if not isinstance(loaded, dict):
        raise HookCollisionError(f"organization profile must contain a mapping/object: {path}")
    return loaded


def _load_upstream_packager(source: Path) -> ModuleType:
    packager_path = source / "scripts" / "package_internal_plugin.py"
    if not packager_path.is_file():
        raise HookCollisionError(f"selected upstream has no packager: {packager_path}")

    spec = importlib.util.spec_from_file_location("_selected_appsec_advisor_packager", packager_path)
    if spec is None or spec.loader is None:
        raise HookCollisionError(f"cannot load selected upstream packager: {packager_path}")
    module = importlib.util.module_from_spec(spec)
    try:
        # Importing the selected packager is read-only. Avoid leaving __pycache__
        # in the generated upstream checkout, which is copied into the package.
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    except Exception as exc:  # noqa: BLE001 - turn an upstream import failure into a stable CLI error
        raise HookCollisionError(f"cannot inspect selected upstream packager {packager_path}: {exc}") from exc
    return module


def upstream_hook_ids(source: Path) -> set[str]:
    module = _load_upstream_packager(source)
    discover = getattr(module, "_available_hook_ids", None)
    if not callable(discover):
        raise HookCollisionError(
            "selected upstream packager does not expose hook-id discovery; "
            "update this packaging template before building that upstream ref"
        )
    try:
        hook_ids = discover(source)
    except Exception as exc:  # noqa: BLE001 - preserve a concise boundary error
        raise HookCollisionError(f"cannot discover hooks in selected upstream {source}: {exc}") from exc
    if not isinstance(hook_ids, set) or any(not isinstance(item, str) or not item for item in hook_ids):
        raise HookCollisionError("selected upstream returned an invalid hook-id set")
    return hook_ids


def organization_hook_ids(profile: Path) -> set[str]:
    hooks = _load_mapping(profile).get("hooks") or {}
    if not isinstance(hooks, dict):
        # The upstream schema validator reports the richer structural error.
        raise HookCollisionError("organization profile hooks must be a mapping/object")
    return {str(hook_id) for hook_id in hooks}


def check(source: Path, profile: Path) -> set[str]:
    collisions = upstream_hook_ids(source.resolve()) & organization_hook_ids(profile.resolve())
    if collisions:
        names = ", ".join(sorted(collisions))
        raise HookCollisionError(
            f"organization hook ids collide with selected upstream hooks: {names}. "
            "To replace behavior, remove the upstream id from plugin_surface.hooks.include, "
            "declare the organization hook under a distinct organization-prefixed id, and "
            "add that new id to the allowlist"
        )
    return collisions


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="selected appsec-advisor checkout")
    parser.add_argument("--profile", type=Path, required=True, help="organization profile YAML")
    args = parser.parse_args()
    try:
        check(args.source, args.profile)
    except HookCollisionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
