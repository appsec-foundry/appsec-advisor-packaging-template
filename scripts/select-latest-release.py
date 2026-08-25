#!/usr/bin/env python3
"""Print the highest valid v-prefixed SemVer tag read from stdin."""

from __future__ import annotations

import re
import sys


SEMVER_TAG = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def parse_tag(tag: str) -> tuple[tuple[int, int, int], tuple[str, ...] | None] | None:
    match = SEMVER_TAG.fullmatch(tag)
    if not match:
        return None
    prerelease = match.group(4)
    identifiers = tuple(prerelease.split(".")) if prerelease else None
    if identifiers and any(
        value.isdigit() and len(value) > 1 and value.startswith("0")
        for value in identifiers
    ):
        return None
    return (int(match.group(1)), int(match.group(2)), int(match.group(3))), identifiers


def compare(left: tuple[str, tuple], right: tuple[str, tuple]) -> int:
    left_tag, (left_core, left_pre) = left
    right_tag, (right_core, right_pre) = right
    if left_core != right_core:
        return (left_core > right_core) - (left_core < right_core)
    if left_pre is None or right_pre is None:
        if left_pre is None and right_pre is None:
            return (left_tag > right_tag) - (left_tag < right_tag)
        return 1 if left_pre is None else -1
    for left_value, right_value in zip(left_pre, right_pre):
        if left_value == right_value:
            continue
        left_numeric = left_value.isdigit()
        right_numeric = right_value.isdigit()
        if left_numeric and right_numeric:
            return (int(left_value) > int(right_value)) - (
                int(left_value) < int(right_value)
            )
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return (left_value > right_value) - (left_value < right_value)
    if len(left_pre) != len(right_pre):
        return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))
    return (left_tag > right_tag) - (left_tag < right_tag)


def main() -> int:
    latest: tuple[str, tuple] | None = None
    for raw_line in sys.stdin:
        candidate = raw_line.rstrip("\r\n").rsplit("/", 1)[-1]
        parsed = parse_tag(candidate)
        if parsed is not None:
            selected = (candidate, parsed)
            if latest is None or compare(selected, latest) > 0:
                latest = selected
    if latest is not None:
        print(latest[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
