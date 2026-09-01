#!/usr/bin/env python3
"""Read-only drift check for the secure-coding baseline configured by a package."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
from typing import Any
import urllib.error
import urllib.request
from urllib.parse import urlsplit

import yaml


MAX_FETCH_BYTES = 1_048_576
FETCH_TIMEOUT_SECONDS = 15
# The id opens its own line; whatever sentence follows it — an em dash, a full
# stop — is not part of the id, and an id never ends in punctuation.
MARKER_PATTERN = re.compile(
    r"(?m)^\s*`?baseline-id:\s*`?"
    r"([A-Za-z0-9](?:[A-Za-z0-9._+-]{0,78}[A-Za-z0-9])?)`?"
    r"(?:[ \t.,;:—-].*)?$"
)
CURRENT_BASELINE_URL = (
    "https://raw.githubusercontent.com/appsec-foundry/"
    "aiscb/main/secure-coding-baseline.md"
)
# Sources that still resolve through GitHub's rename and transfer redirects. A
# profile configured against one of them is checked against the current URL.
LEGACY_BASELINE_URLS = (
    "https://raw.githubusercontent.com/matthiasrohr/"
    "ai-secure-coding-baseline/main/secure-coding-baseline.md",
    "https://raw.githubusercontent.com/appsec-foundry/"
    "ai-secure-coding-baseline/main/secure-coding-baseline.md",
)


class BaselineCheckError(ValueError):
    """The configured baseline cannot be checked safely or accurately."""


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise BaselineCheckError(
            f"core config not found at {path}; run 'make package' first"
        ) from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BaselineCheckError(f"cannot read core config {path}: {error}") from error
    if not isinstance(value, dict):
        raise BaselineCheckError(f"core config must be a JSON object: {path}")
    return value


def _read_yaml(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise BaselineCheckError(f"organization profile not found: {path}") from error
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        raise BaselineCheckError(f"cannot read organization profile {path}: {error}") from error
    if not isinstance(value, dict):
        raise BaselineCheckError(f"organization profile must be a YAML mapping: {path}")
    return value


def _effective_baseline(profile: dict[str, Any], core: dict[str, Any]) -> dict[str, Any]:
    core_baseline = core.get("baseline")
    if not isinstance(core_baseline, dict):
        raise BaselineCheckError("core config has no baseline object")
    effective = dict(core_baseline)
    profile_baseline = profile.get("baseline")
    if profile_baseline is None:
        return effective
    if not isinstance(profile_baseline, dict):
        raise BaselineCheckError("organization profile baseline must be a mapping")

    # Match the upstream packager: naming an organization source replaces the
    # inherited source rather than accidentally retaining the core URL.
    if any(key in profile_baseline for key in ("id", "url", "git", "file")):
        for key in ("url", "git", "fallback_file"):
            effective.pop(key, None)
    effective.update(profile_baseline)
    return effective


def _marker(document: bytes, origin: str) -> str:
    if len(document) > MAX_FETCH_BYTES:
        raise BaselineCheckError(
            f"baseline document exceeds {MAX_FETCH_BYTES} bytes: {origin}"
        )
    try:
        text = document.decode("utf-8")
    except UnicodeDecodeError as error:
        raise BaselineCheckError(f"baseline document is not UTF-8: {origin}") from error
    markers = MARKER_PATTERN.findall(text)
    if len(markers) != 1:
        detail = "none" if not markers else ", ".join(markers)
        raise BaselineCheckError(
            f"baseline document must contain exactly one baseline-id marker; found {detail}: {origin}"
        )
    return markers[0]


def _load_url_guard(core_config_path: Path):
    path = core_config_path.parent / "scripts" / "_url_guard.py"
    if not path.is_file():
        raise BaselineCheckError(f"core URL guard not found: {path}")
    spec = importlib.util.spec_from_file_location("appsec_baseline_url_guard", path)
    if spec is None or spec.loader is None:
        raise BaselineCheckError(f"cannot load core URL guard: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _profile_allowlist(profile: dict[str, Any]) -> list[str]:
    policy = profile.get("policy", {})
    if not isinstance(policy, dict):
        raise BaselineCheckError("organization profile policy must be a mapping")
    hosts = policy.get("url_allowlist", [])
    if hosts is None:
        return []
    if not isinstance(hosts, list) or any(not isinstance(host, str) or not host.strip() for host in hosts):
        raise BaselineCheckError("policy.url_allowlist must contain host names")
    return [host.strip().lower() for host in hosts]


def _fetch(url: str, profile: dict[str, Any], core_config_path: Path) -> bytes:
    parsed = urlsplit(url)
    if parsed.scheme != "https":
        raise BaselineCheckError("baseline drift checks require an HTTPS source URL")
    if not parsed.hostname or parsed.username is not None or parsed.password is not None:
        raise BaselineCheckError("baseline source URL must have a host and no credentials")

    guard = _load_url_guard(core_config_path)
    configured_hosts = _profile_allowlist(profile)
    previous_allowlist = os.environ.get("APPSEC_URL_ALLOWLIST")
    combined_hosts = set(configured_hosts)
    if previous_allowlist:
        combined_hosts.update(
            host.strip().lower() for host in previous_allowlist.split(",") if host.strip()
        )
    if combined_hosts:
        os.environ["APPSEC_URL_ALLOWLIST"] = ",".join(sorted(combined_hosts))
    try:
        verdict = guard.validate_target_url(url, check_ip_safety=False)
        if not verdict.ok:
            raise BaselineCheckError(f"baseline URL blocked by URL guard: {verdict.reason}")
        class HTTPSOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D401, ARG002, N802
                if urlsplit(newurl).scheme != "https":
                    raise urllib.error.HTTPError(
                        newurl, code, "redirect rejected: HTTPS is required", headers, fp
                    )
                redirect_verdict = guard.validate_target_url(
                    newurl, check_ip_safety=False
                )
                if not redirect_verdict.ok:
                    raise urllib.error.HTTPError(
                        newurl,
                        code,
                        f"redirect rejected: {redirect_verdict.reason}",
                        headers,
                        fp,
                    )
                return super().redirect_request(req, fp, code, msg, headers, newurl)

        opener = urllib.request.build_opener(HTTPSOnlyRedirectHandler())
        request = urllib.request.Request(
            url,
            headers={"Accept": "text/markdown, text/plain", "User-Agent": "appsec-advisor-baseline-check/1"},
        )
        try:
            with opener.open(request, timeout=FETCH_TIMEOUT_SECONDS) as response:  # noqa: S310
                length = response.headers.get("Content-Length")
                if length and int(length) > MAX_FETCH_BYTES:
                    raise BaselineCheckError(
                        f"baseline document exceeds {MAX_FETCH_BYTES} bytes: {url}"
                    )
                document = response.read(MAX_FETCH_BYTES + 1)
        except BaselineCheckError:
            raise
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise BaselineCheckError(f"cannot fetch baseline source {url}: {error}") from error
    finally:
        if previous_allowlist is None:
            os.environ.pop("APPSEC_URL_ALLOWLIST", None)
        else:
            os.environ["APPSEC_URL_ALLOWLIST"] = previous_allowlist
    return document


def check(
    profile_path: Path,
    core_config_path: Path,
    *,
    document_path: Path | None = None,
) -> int:
    profile = _read_yaml(profile_path)
    core = _read_json(core_config_path)
    baseline = _effective_baseline(profile, core)

    enabled = baseline.get("enabled", True)
    if not isinstance(enabled, bool):
        raise BaselineCheckError("effective baseline.enabled must be boolean")
    if not enabled:
        print("baseline: disabled in organization profile")
        print("SKIP: no baseline upstream check is applicable")
        return 0

    expected = baseline.get("id")
    if not isinstance(expected, str) or not expected.strip():
        raise BaselineCheckError("effective baseline has no valid id")
    expected = expected.strip()

    url = baseline.get("url")
    if document_path is not None:
        try:
            document = document_path.read_bytes()
        except OSError as error:
            raise BaselineCheckError(f"cannot read baseline document {document_path}: {error}") from error
        origin = str(document_path)
    else:
        if not isinstance(url, str) or not url.strip():
            source_type = "git" if baseline.get("git") else "local file"
            raise BaselineCheckError(
                f"effective baseline uses {source_type}; this check currently requires a URL source"
            )
        url = CURRENT_BASELINE_URL if url in LEGACY_BASELINE_URLS else url.strip()
        document = _fetch(url, profile, core_config_path)
        origin = url

    published = _marker(document, origin)
    print(f"baseline source: {origin}")
    print(f"configured id:  {expected}")
    print(f"published id:   {published}")
    if published != expected:
        print(f"DRIFT (baseline): published {published}, configured {expected}")
        return 1
    print(f"OK: baseline is current at {expected}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--core-config", type=Path, required=True)
    parser.add_argument(
        "--document",
        type=Path,
        help="read a local document instead of the configured URL (for offline verification)",
    )
    args = parser.parse_args()
    try:
        return check(args.profile, args.core_config, document_path=args.document)
    except BaselineCheckError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
