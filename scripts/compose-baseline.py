#!/usr/bin/env python3
"""Compose the vendored secure-coding baseline with an optional org overlay.

`org-profile/baselines/<file>` is also the target of `make baseline-sync`,
which overwrites it with freshly fetched upstream text. Appending org rules
directly into that file (the documented `+suffix` convention) means an
unattended sync silently destroys them. `organization-overlay.md`, sibling to
the baseline file, is never touched by sync: when it exists, this script
concatenates the base file with it and overwrites the base file *in the
directory it is given* — the caller is expected to pass a throwaway copy of
`org-profile/`, never the tracked one, so the composition never lands in Git.

The overlay must not declare its own `baseline-id:` line: the id stays owned
by the base file and `baseline.id` in the profile, matching the existing
`+suffix` convention. A composed document with more than one id marker is
rejected the same way `baseline-upstream-check.py` rejects one on fetch.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
from typing import Any

import yaml

DEFAULT_BASELINE_FILE = "baselines/secure-coding-baseline.md"
OVERLAY_NAME = "organization-overlay.md"
# Same marker convention as scripts/baseline-upstream-check.py: the id opens
# its own line, and the sentence that may follow it is not part of the id.
MARKER_PATTERN = re.compile(
    r"(?m)^\s*`?baseline-id:\s*`?"
    r"([A-Za-z0-9](?:[A-Za-z0-9._+-]{0,78}[A-Za-z0-9])?)`?"
    r"(?:[ \t.,;:—-].*)?$"
)


class ComposeError(ValueError):
    """The base baseline and its overlay cannot be composed safely."""


def _baseline_file(org_profile_dir: Path) -> str:
    profile_path = org_profile_dir / "org-profile.yaml"
    try:
        data = yaml.safe_load(profile_path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ComposeError(f"cannot read organization profile {profile_path}: {error}") from error
    except yaml.YAMLError as error:
        raise ComposeError(f"organization profile is not valid YAML: {profile_path}: {error}") from error
    baseline: Any = data.get("baseline") if isinstance(data, dict) else None
    if isinstance(baseline, dict) and isinstance(baseline.get("file"), str) and baseline["file"]:
        return baseline["file"]
    return DEFAULT_BASELINE_FILE


def compose(org_profile_dir: Path) -> bool:
    """Overwrite the base baseline file in place if an overlay exists.

    Returns whether an overlay was found and composed. A no-op (returns
    False) leaves the base file untouched, including its bytes.
    """
    overlay_path = org_profile_dir / "baselines" / OVERLAY_NAME
    if not overlay_path.is_file():
        return False

    base_path = org_profile_dir / _baseline_file(org_profile_dir)
    try:
        base_text = base_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ComposeError(f"cannot read base baseline {base_path}: {error}") from error
    try:
        overlay_text = overlay_path.read_text(encoding="utf-8")
    except OSError as error:
        raise ComposeError(f"cannot read baseline overlay {overlay_path}: {error}") from error

    composed = base_text.rstrip("\n") + "\n\n" + overlay_text.strip("\n") + "\n"
    ids = MARKER_PATTERN.findall(composed)
    if len(ids) != 1:
        detail = "none" if not ids else ", ".join(ids)
        raise ComposeError(
            "composed baseline must contain exactly one baseline-id marker; found "
            f"{detail}. Keep the id in {base_path.name} only — {OVERLAY_NAME} extends "
            "the rules, not the version marker."
        )

    try:
        base_path.write_text(composed, encoding="utf-8")
    except OSError as error:
        raise ComposeError(f"cannot write composed baseline {base_path}: {error}") from error
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--org-profile",
        type=Path,
        required=True,
        help="org-profile directory to compose in place (pass a throwaway copy, never the tracked one)",
    )
    args = parser.parse_args()
    try:
        composed = compose(args.org_profile.resolve())
    except ComposeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    if composed:
        print(f"==> Composed the baseline with {OVERLAY_NAME}")
    else:
        print(f"==> No {OVERLAY_NAME} found; baseline is used as vendored")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
