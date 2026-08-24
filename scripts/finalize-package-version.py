#!/usr/bin/env python3
"""Set the organization package version without losing the upstream core version."""

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from pathlib import Path


class FinalizeError(ValueError):
    """The packaged tree cannot be finalized safely."""


VERSION_READER = 'return json.loads(meta.read_text()).get("version", "0.0.0")'
CORE_VERSION_READER = """data = json.loads(meta.read_text())
        return data.get("appsec_advisor_core_version", data.get("version", "0.0.0"))"""


def _read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise FinalizeError(f"required file is missing: {path}") from exc
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise FinalizeError(f"cannot read valid UTF-8 JSON from {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise FinalizeError(f"expected a JSON object in {path}")
    return data


def _write_text_atomic(path: Path, text: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _write_json_atomic(path: Path, data: dict) -> None:
    _write_text_atomic(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def finalize(plugin_root: Path, package_version: str, core_version: str) -> None:
    manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
    validator_path = plugin_root / "scripts" / "validate_org_profile.py"

    manifest = _read_json(manifest_path)
    if manifest.get("version") != core_version:
        raise FinalizeError(
            "packaged manifest version does not match the expected upstream core "
            f"version: {manifest.get('version')!r} != {core_version!r}"
        )

    try:
        validator = validator_path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise FinalizeError(f"required file is missing: {validator_path}") from exc
    except (OSError, UnicodeDecodeError) as exc:
        raise FinalizeError(f"cannot read valid UTF-8 from {validator_path}: {exc}") from exc

    occurrences = validator.count(VERSION_READER)
    if occurrences != 1:
        raise FinalizeError(
            "upstream org-profile validator no longer has the expected version reader; "
            "update the packaging adapter before using this upstream release"
        )

    manifest["version"] = package_version
    manifest["appsec_advisor_core_version"] = core_version
    # Change the reader first. If writing the manifest then fails, it safely
    # falls back to the still-current `version` field.
    _write_text_atomic(
        validator_path,
        validator.replace(VERSION_READER, CORE_VERSION_READER),
    )
    _write_json_atomic(manifest_path, manifest)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply an organization-owned version to a packaged appsec-advisor plugin."
    )
    parser.add_argument("--plugin-root", required=True, type=Path)
    parser.add_argument("--package-version", required=True)
    parser.add_argument("--core-version", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        finalize(args.plugin_root.resolve(), args.package_version, args.core_version)
    except FinalizeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
