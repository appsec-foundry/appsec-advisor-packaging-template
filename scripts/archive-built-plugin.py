#!/usr/bin/env python3
"""Archive an already generated and smoke-tested plugin directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile
import tempfile


PLUGIN_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VERSION_PATTERN = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]*$")


class ArchiveError(ValueError):
    """The requested archive identity does not match the packaged plugin."""


def _validate_identity(name: object, version: object) -> tuple[str, str]:
    if not isinstance(name, str) or not PLUGIN_NAME_PATTERN.fullmatch(name):
        raise ArchiveError("packaged plugin contains an invalid name")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ArchiveError("packaged plugin contains an invalid version")
    return name, version


def remove_stale_archive(name: str, version: str, dist_dir: Path) -> None:
    name, version = _validate_identity(name, version)
    for path in (
        dist_dir / f"{name}-{version}.tgz",
        dist_dir / f"{name}-{version}.tgz.sha256",
    ):
        if path.is_file() or path.is_symlink():
            path.unlink()


def archive_plugin(plugin_root: Path, dist_dir: Path) -> tuple[Path, Path]:
    plugin_root = plugin_root.resolve()
    manifest_path = plugin_root / ".claude-plugin" / "plugin.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError) as error:
        raise ArchiveError(
            f"cannot read packaged plugin manifest {manifest_path}: {error}"
        ) from error
    if not isinstance(manifest, dict):
        raise ArchiveError(
            f"packaged plugin manifest must be an object: {manifest_path}"
        )
    name, version = _validate_identity(manifest.get("name"), manifest.get("version"))

    dist_dir.mkdir(parents=True, exist_ok=True)
    tar_path = dist_dir / f"{name}-{version}.tgz"
    sha_path = dist_dir / f"{name}-{version}.tgz.sha256"
    temporary_tar = ""
    temporary_sha = ""
    try:
        with tempfile.NamedTemporaryFile(
            dir=dist_dir, suffix=".tgz", delete=False
        ) as file:
            temporary_tar = file.name
        with tarfile.open(temporary_tar, "w:gz") as archive:
            archive.add(plugin_root, arcname=name)
        digest = hashlib.sha256(Path(temporary_tar).read_bytes()).hexdigest()

        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=dist_dir, delete=False
        ) as file:
            temporary_sha = file.name
            file.write(f"{digest}  {tar_path.name}\n")
            file.flush()
            os.fchmod(file.fileno(), 0o644)
        os.replace(temporary_tar, tar_path)
        temporary_tar = ""
        os.replace(temporary_sha, sha_path)
        temporary_sha = ""
    finally:
        for temporary in (temporary_tar, temporary_sha):
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
    return tar_path, sha_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-root", type=Path)
    parser.add_argument("--dist-dir", type=Path, default=Path("dist"))
    parser.add_argument("--clean-only", action="store_true")
    parser.add_argument("--name")
    parser.add_argument("--version")
    args = parser.parse_args()
    try:
        if args.clean_only:
            if args.name is None or args.version is None:
                raise ArchiveError("--clean-only requires --name and --version")
            remove_stale_archive(args.name, args.version, args.dist_dir)
            return 0
        if args.plugin_root is None:
            raise ArchiveError("--plugin-root is required unless --clean-only is used")
        tar_path, sha_path = archive_plugin(args.plugin_root, args.dist_dir)
    except ArchiveError as error:
        parser.error(str(error))
    print(f"Archive: {tar_path}")
    print(f"Checksum: {sha_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
