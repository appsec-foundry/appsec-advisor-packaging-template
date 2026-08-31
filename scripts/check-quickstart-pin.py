#!/usr/bin/env python3
"""Verify that the README quick start pins the initializer it actually ships.

The quick start downloads ``scripts/init-org-repo.sh`` from an immutable commit
and checks a SHA-256 before running it. Both halves go stale the moment the
initializer changes, and nothing notices: the download keeps working, it just
delivers an older script, and a maintainer who repins the commit but not the
digest turns the block into a checksum failure for every new user.

Deliberately not part of ``make check``. The documented workflow commits the
initializer first and repins the README in a follow-up commit, so the two
disagree in between; failing there would make the prescribed sequence
unusable. A release must not carry that intermediate state, which is why this
runs at the release boundary instead.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

INITIALIZER = "scripts/init-org-repo.sh"
URL_PATTERN = re.compile(
    r"appsec-advisor-packaging-template/(?P<ref>[^/\s]+)/scripts/init-org-repo\.sh"
)
DIGEST_PATTERN = re.compile(r"echo '(?P<digest>[0-9a-f]{64})  appsec-advisor-init\.sh'")


class PinError(ValueError):
    """The quick start does not describe the initializer this repository ships."""


def _single(pattern: re.Pattern[str], text: str, group: str, what: str) -> str:
    found = {match.group(group) for match in pattern.finditer(text)}
    if len(found) != 1:
        raise PinError(f"README.md must name exactly one {what}; found {len(found)}")
    return found.pop()


def _committed_bytes(repo: Path, ref: str) -> bytes | None:
    """The initializer as of ``ref``, or None when the commit is not available.

    A shallow CI clone may not carry it. That is a reason to fall back to the
    worktree, not to fail: the digest comparison below still catches a stale pin.
    """
    try:
        result = subprocess.run(  # noqa: S603
            ["git", "-C", str(repo), "show", f"{ref}:{INITIALIZER}"],
            capture_output=True,
            check=False,
        )
    except OSError:
        return None
    return result.stdout if result.returncode == 0 else None


def check(repo: Path, *, read_commit: object = None) -> int:
    readme = repo / "README.md"
    initializer = repo / INITIALIZER
    try:
        text = readme.read_text(encoding="utf-8")
        shipped = initializer.read_bytes()
    except OSError as error:
        raise PinError(f"cannot read the quick start sources: {error}") from error

    ref = _single(URL_PATTERN, text, "ref", "initializer download URL")
    declared = _single(DIGEST_PATTERN, text, "digest", "initializer checksum")

    if not re.fullmatch(r"[0-9a-f]{40}", ref):
        raise PinError(
            f"the quick start URL must pin a full commit, not '{ref}' — "
            "a branch or tag moves under the checksum beside it"
        )

    shipped_digest = hashlib.sha256(shipped).hexdigest()
    if declared != shipped_digest:
        raise PinError(
            f"the quick start checksum does not describe {INITIALIZER}\n"
            f"  README declares: {declared}\n"
            f"  shipped file is: {shipped_digest}\n"
            f"Repin the URL to the commit that published the current initializer "
            f"and update the checksum beside it."
        )

    # Injectable so the tests never depend on an ambient git: the suite puts a
    # stub on PATH, and a stub that exits 0 with unrelated output is
    # indistinguishable from a real answer here.
    reader = _committed_bytes if read_commit is None else read_commit
    pinned = reader(repo, ref)
    if pinned is None:
        print(f"OK: quick start checksum matches {INITIALIZER} (pinned commit not available locally)")
        return 0
    if hashlib.sha256(pinned).hexdigest() != shipped_digest:
        raise PinError(
            f"the pinned commit {ref} carries a different {INITIALIZER} than this repository ships — "
            "repin the URL to the commit that published the current one"
        )
    print(f"OK: quick start pins {ref} and matches {INITIALIZER}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="repository root to check")
    args = parser.parse_args()
    try:
        return check(args.repo)
    except PinError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
