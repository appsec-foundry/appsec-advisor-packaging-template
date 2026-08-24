#!/usr/bin/env python3
"""Remove inactive session-banner code from an already packaged plugin."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


class SessionBannerPruneError(ValueError):
    """The package surface cannot be safely reconciled."""


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise SessionBannerPruneError(f"required packaged metadata is missing: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SessionBannerPruneError(f"cannot read packaged metadata {path}: {error}") from error
    if not isinstance(value, dict):
        raise SessionBannerPruneError(f"packaged metadata must be a JSON object: {path}")
    return value


def prune(plugin_root: Path) -> bool:
    plugin_root = plugin_root.resolve()
    surface = _read_json(plugin_root / ".claude-plugin" / "package-surface.json")
    hooks = surface.get("hooks")
    if not isinstance(hooks, dict) or not isinstance(hooks.get("included"), list):
        raise SessionBannerPruneError("package surface must contain hooks.included")
    included = hooks["included"]
    if any(not isinstance(name, str) for name in included):
        raise SessionBannerPruneError("package surface hooks.included must contain names")
    if "session-banner" in included:
        return False

    hooks_json = _read_json(plugin_root / "hooks" / "hooks.json")
    serialized_hooks = json.dumps(hooks_json, sort_keys=True)
    if "session_banner.py" in serialized_hooks or "session-banner" in serialized_hooks:
        raise SessionBannerPruneError(
            "package surface removes session-banner but hooks.json still registers it"
        )

    script = plugin_root / "scripts" / "session_banner.py"
    if script.is_symlink():
        raise SessionBannerPruneError(f"refusing to remove symlinked packaged script: {script}")
    if not script.exists():
        return False
    if not script.is_file():
        raise SessionBannerPruneError(f"packaged session banner is not a regular file: {script}")
    script.unlink()
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        removed = prune(args.plugin_root)
    except SessionBannerPruneError as error:
        parser.error(str(error))
    state = "removed" if removed else "unchanged"
    print(f"Packaged session banner: {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
