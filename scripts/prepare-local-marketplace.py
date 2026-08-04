#!/usr/bin/env python3
"""Expose a packaged plugin through a generated local marketplace catalog."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def valid_name(value: str) -> str:
    if not NAME_PATTERN.fullmatch(value):
        raise argparse.ArgumentTypeError(
            "must be kebab-case: lowercase letters, digits and hyphens"
        )
    return value


def prepare(build_root: Path, plugin_name: str, marketplace_name: str) -> Path:
    plugin_root = build_root / plugin_name
    plugin_manifest = plugin_root / ".claude-plugin" / "plugin.json"
    if not plugin_manifest.is_file():
        raise FileNotFoundError(
            f"packaged plugin manifest not found: {plugin_manifest}; run make package first"
        )

    catalog = {
        "name": marketplace_name,
        "owner": {"name": "Local development"},
        "description": f"Generated local marketplace for {plugin_name}",
        "plugins": [
            {
                "name": plugin_name,
                "source": f"./{plugin_name}",
            }
        ],
    }
    catalog_path = build_root / ".claude-plugin" / "marketplace.json"
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    catalog_path.write_text(json.dumps(catalog, indent=2) + "\n", encoding="utf-8")
    return catalog_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--plugin-name", type=valid_name, required=True)
    parser.add_argument("--marketplace-name", type=valid_name, required=True)
    args = parser.parse_args()

    try:
        catalog_path = prepare(
            args.build_root, args.plugin_name, args.marketplace_name
        )
    except FileNotFoundError as error:
        parser.error(str(error))
    print(f"Local marketplace ready: {catalog_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
