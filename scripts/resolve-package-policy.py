#!/usr/bin/env python3
"""Resolve `optional_skills` in the package policy against the selected upstream.

The upstream packager validates `plugin_surface.skills.include` against the
skills that actually exist in the ref being built and aborts on a name it does
not know. A skill that upstream has only on a branch can therefore not be listed
ahead of its release: the entry would break every build from the pinned tag.

`optional_skills` closes that gap without turning the allowlist into a
blocklist. A name listed there is still an explicit organization decision to
ship that skill; it is merely allowed to be absent. When the selected ref has
the skill it is appended to the allowlist, otherwise it is dropped with a note.
Names under `plugin_surface` keep the strict upstream check, so a typo there
still fails the build.

The resolved policy is written to a separate file and handed to the packager via
`--package-policy`. The policy in `org-profile/` is never modified.
"""

from __future__ import annotations

import argparse
import copy
import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

import yaml

SKILL_NAME = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


class PolicyResolutionError(ValueError):
    """Raised when the package policy cannot be resolved safely."""


def _load_mapping(path: Path) -> dict[str, Any]:
    try:
        loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise PolicyResolutionError(f"cannot read package policy {path}: {exc}") from exc
    except UnicodeDecodeError as exc:
        raise PolicyResolutionError(f"package policy is not valid UTF-8: {path}: {exc}") from exc
    except yaml.YAMLError as exc:
        raise PolicyResolutionError(f"package policy is not valid YAML: {path}: {exc}") from exc
    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise PolicyResolutionError(f"package policy must contain a mapping/object: {path}")
    return loaded


def _load_upstream_packager(source: Path) -> ModuleType:
    packager_path = source / "scripts" / "package_internal_plugin.py"
    if not packager_path.is_file():
        raise PolicyResolutionError(f"selected upstream has no packager: {packager_path}")

    spec = importlib.util.spec_from_file_location("_selected_appsec_advisor_packager", packager_path)
    if spec is None or spec.loader is None:
        raise PolicyResolutionError(f"cannot load selected upstream packager: {packager_path}")
    module = importlib.util.module_from_spec(spec)
    try:
        # Read-only inspection; do not leave __pycache__ in the checkout that is
        # copied into the package.
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    except Exception as exc:  # noqa: BLE001 - turn an upstream import failure into a stable CLI error
        raise PolicyResolutionError(f"cannot inspect selected upstream packager {packager_path}: {exc}") from exc
    return module


def upstream_skill_ids(source: Path) -> set[str]:
    """Skill ids the selected upstream would offer, derived by its own packager."""
    module = _load_upstream_packager(source)
    discover = getattr(module, "_available_skills", None)
    if not callable(discover):
        raise PolicyResolutionError(
            "selected upstream packager does not expose skill discovery; "
            "update this packaging template before building that upstream ref"
        )
    try:
        skill_ids = discover(source)
    except Exception as exc:  # noqa: BLE001 - preserve a concise boundary error
        raise PolicyResolutionError(f"cannot discover skills in selected upstream {source}: {exc}") from exc
    if not isinstance(skill_ids, set) or any(not isinstance(item, str) or not item for item in skill_ids):
        raise PolicyResolutionError("selected upstream returned an invalid skill-id set")
    return skill_ids


def _optional_names(policy: dict[str, Any]) -> list[str]:
    raw = policy.get("optional_skills")
    if raw is None:
        return []
    if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
        raise PolicyResolutionError("package policy optional_skills must be a list of strings")
    names: list[str] = []
    for item in raw:
        name = item.strip()
        if not SKILL_NAME.fullmatch(name):
            raise PolicyResolutionError(
                "package policy optional_skills contains an invalid skill name: "
                f"{item!r} (expected lowercase letters, digits, '.', '_' and '-')"
            )
        if name in names:
            raise PolicyResolutionError(f"package policy optional_skills contains duplicates: {name}")
        names.append(name)
    return names


def resolve(policy: dict[str, Any], available: set[str]) -> tuple[dict[str, Any], list[str], list[str]]:
    """Return the resolved policy plus the names that were kept and dropped."""
    resolved = copy.deepcopy(policy)
    optional = _optional_names(resolved)
    resolved.pop("optional_skills", None)
    if not optional:
        return resolved, [], []

    surface = resolved.get("plugin_surface")
    if not isinstance(surface, dict):
        raise PolicyResolutionError("package policy optional_skills requires a plugin_surface mapping/object")
    skills = surface.get("skills")
    if not isinstance(skills, dict) or not isinstance(skills.get("include"), list):
        raise PolicyResolutionError(
            "package policy optional_skills requires plugin_surface.skills.include; "
            "an exclude list already ships every skill the selected ref has"
        )

    include = skills["include"]
    kept: list[str] = []
    dropped: list[str] = []
    for name in optional:
        if name in include:
            raise PolicyResolutionError(
                f"skill '{name}' is listed both in plugin_surface.skills.include and in "
                "optional_skills; keep it in one of them"
            )
        if name in available:
            include.append(name)
            kept.append(name)
        else:
            dropped.append(name)
    return resolved, kept, dropped


def _write(path: Path, policy: dict[str, Any]) -> None:
    try:
        path.write_text(yaml.safe_dump(policy, sort_keys=False), encoding="utf-8")
    except OSError as exc:
        raise PolicyResolutionError(f"cannot write resolved package policy {path}: {exc}") from exc


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="selected appsec-advisor checkout")
    parser.add_argument("--policy", type=Path, required=True, help="organization package policy YAML")
    parser.add_argument("--out", type=Path, required=True, help="path for the resolved policy")
    args = parser.parse_args()
    try:
        policy = _load_mapping(args.policy)
        resolved, kept, dropped = resolve(policy, upstream_skill_ids(args.source.resolve()))
        _write(args.out, resolved)
    except PolicyResolutionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    for name in kept:
        print(f"==> Optional skill '{name}' exists in the selected upstream — included")
    for name in dropped:
        print(f"==> Optional skill '{name}' is absent from the selected upstream — skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
