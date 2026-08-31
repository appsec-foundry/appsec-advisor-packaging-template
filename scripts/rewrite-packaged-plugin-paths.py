#!/usr/bin/env python3
"""Point the packaged plugin-root fallbacks at the internal plugin directory."""

from __future__ import annotations

import argparse
import os
import stat
import sys
import tempfile
from pathlib import Path


UPSTREAM_DIRECTORY = "appsec-advisor"
# Several upstream skills and agents locate the plugin by directory name when
# CLAUDE_PLUGIN_ROOT is unset, for example
#   find /root /home /opt -maxdepth 6 -path "*/appsec-advisor/skills/status/SKILL.md"
# The package is installed under INTERNAL_NAME, so the upstream name never
# matches and the fallback fails. The quoted glob anchors the rewrite:
# repository links such as github.com/appsec-foundry/appsec-advisor and prose
# that mentions the upstream name carry no `"*/` prefix and stay untouched.
GLOB_PREFIX = '"*/'
RESIDUAL_GLOB = f"*/{UPSTREAM_DIRECTORY}/"


class RewriteError(ValueError):
    """The packaged tree cannot be rewritten safely."""


def _write_atomic(path: Path, text: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def rewrite(plugin_root: Path, name: str) -> int:
    if not plugin_root.is_dir():
        raise RewriteError(f"packaged plugin root is missing: {plugin_root}")
    if not name:
        raise RewriteError("internal plugin name must not be empty")
    if name == UPSTREAM_DIRECTORY:
        return 0

    old = f"{GLOB_PREFIX}{UPSTREAM_DIRECTORY}/"
    new = f"{GLOB_PREFIX}{name}/"
    updates: list[tuple[Path, str]] = []
    residual: list[str] = []

    for path in sorted(plugin_root.rglob("*")):
        if path.is_symlink():
            raise RewriteError(f"refusing to inspect packaged symlink: {path}")
        if not path.is_file():
            continue
        try:
            raw = path.read_bytes()
        except OSError as exc:
            raise RewriteError(f"cannot read packaged file {path}: {exc}") from exc
        if RESIDUAL_GLOB.encode() not in raw:
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise RewriteError(
                f"upstream plugin-directory glob appears in non-UTF-8 file {path}"
            ) from exc

        updated = text.replace(old, new)
        if RESIDUAL_GLOB in updated:
            residual.append(str(path.relative_to(plugin_root)))
        elif updated != text:
            updates.append((path, updated))

    if residual:
        files = ", ".join(residual[:10])
        raise RewriteError(
            "packaged files still resolve the plugin through the upstream "
            f"directory name; extend the rewrite before packaging: {files}"
        )

    for path, updated in updates:
        _write_atomic(path, updated)
    return len(updates)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Rewrite upstream plugin-directory globs in a packaged plugin so the "
            "CLAUDE_PLUGIN_ROOT fallback finds the internal package."
        )
    )
    parser.add_argument("--plugin-root", required=True, type=Path)
    parser.add_argument("--name", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        changed = rewrite(args.plugin_root.resolve(), args.name)
    except RewriteError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if changed:
        print(f"Plugin-directory fallbacks retargeted in {changed} packaged file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
