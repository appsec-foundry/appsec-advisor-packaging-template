#!/usr/bin/env python3
"""Print the baseline id that the published secure-coding baseline declares.

The initializer pins this id into a new organization profile, so a scaffolded
repository starts on the current baseline instead of whatever the template
happened to carry.
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.error
import urllib.request
from urllib.parse import urlsplit


BASELINE_URL = (
    "https://raw.githubusercontent.com/appsec-foundry/"
    "aiscb/main/secure-coding-baseline.md"
)
MAX_FETCH_BYTES = 1_048_576
FETCH_TIMEOUT_SECONDS = 15
# Same marker convention as scripts/baseline-upstream-check.py: the id opens its
# own line, and the sentence that may follow it is not part of the id.
MARKER_PATTERN = re.compile(
    r"(?m)^\s*`?baseline-id:\s*`?"
    r"([A-Za-z0-9](?:[A-Za-z0-9._+-]{0,78}[A-Za-z0-9])?)`?"
    r"(?:[ \t.,;:—-].*)?$"
)


class ResolveError(ValueError):
    """The published baseline id cannot be read safely or unambiguously."""


class _HTTPSOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):  # noqa: N802
        if urlsplit(newurl).scheme != "https":
            raise urllib.error.HTTPError(
                newurl, code, "redirect rejected: HTTPS is required", headers, fp
            )
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def marker(document: bytes, origin: str) -> str:
    """Return the single baseline id declared in ``document``."""
    if len(document) > MAX_FETCH_BYTES:
        raise ResolveError(f"baseline document exceeds {MAX_FETCH_BYTES} bytes: {origin}")
    try:
        text = document.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ResolveError(f"baseline document is not UTF-8: {origin}") from error
    ids = sorted(set(MARKER_PATTERN.findall(text)))
    if len(ids) != 1:
        detail = "none" if not ids else ", ".join(ids)
        raise ResolveError(
            f"baseline document must contain exactly one baseline-id marker; found {detail}: {origin}"
        )
    return ids[0]


def fetch(url: str) -> bytes:
    parsed = urlsplit(url)
    if parsed.scheme != "https":
        raise ResolveError("the baseline source must be an HTTPS URL")
    if not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise ResolveError("the baseline source URL must have a host and no credentials")

    opener = urllib.request.build_opener(_HTTPSOnlyRedirectHandler())
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "text/markdown, text/plain",
            "User-Agent": "appsec-advisor-baseline-resolve/1",
        },
    )
    try:
        with opener.open(request, timeout=FETCH_TIMEOUT_SECONDS) as response:  # noqa: S310
            length = response.headers.get("Content-Length")
            if length and int(length) > MAX_FETCH_BYTES:
                raise ResolveError(f"baseline document exceeds {MAX_FETCH_BYTES} bytes: {url}")
            return response.read(MAX_FETCH_BYTES + 1)
    except ResolveError:
        raise
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise ResolveError(f"cannot fetch the baseline source {url}: {error}") from error


def resolve(url: str) -> str:
    return marker(fetch(url), url)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Print the baseline id declared by the published secure-coding baseline."
    )
    parser.add_argument(
        "--url",
        default=BASELINE_URL,
        help="HTTPS source of the baseline document (default: the appsec-foundry baseline)",
    )
    args = parser.parse_args()
    try:
        print(resolve(args.url))
    except ResolveError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
