#!/usr/bin/env python3
"""Render the developer-facing README for an already packaged plugin."""

from __future__ import annotations

import argparse
import html
import json
import os
from pathlib import Path
import re
import tempfile
import textwrap
from typing import Any
from urllib.parse import urlsplit

import yaml


PLUGIN_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
SURFACE_NAME_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
VERSION_PATTERN = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+-]*$")
CORE_REF_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/+-]{0,127}$")
CORE_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{7,64}$")
INTERNAL_SKILLS = {"internal-threat-analysis-kernel"}
PREFERRED_ORDER = (
    "help",
    "check-permissions",
    "create-threat-model",
    "update-threat-model",
    "show-threat-model",
    "ask-threat-model",
    "review-threat-model",
    "threat-model-health",
    "audit-security-requirements",
    "verify-requirements",
    "status",
    "fix-run-issues",
    "clean-run-state",
)
COMMAND_DESCRIPTIONS = {
    "help": "See the commands and policies included in this package.",
    "check-permissions": "Check and update the permissions the plugin needs.",
    "create-threat-model": "Create a threat model for this repository.",
    "update-threat-model": "Bring an existing threat model up to date.",
    "show-threat-model": "Show the current findings and remediation backlog.",
    "ask-threat-model": "Ask read-only questions about the current threat model.",
    "review-threat-model": "Triage findings and work through remediation decisions.",
    "threat-model-health": "Check whether the current model is stale or incomplete.",
    "audit-security-requirements": "Audit the repository against our security requirements.",
    "verify-requirements": "Check recent changes against applicable requirements.",
    "status": "Show the current analysis run state.",
    "fix-run-issues": "Diagnose and repair a failed or interrupted run.",
    "clean-run-state": "Remove stale state before starting a clean run.",
    "install-baseline": "Install the secure-coding baseline for Claude Code.",
    "verify-baseline": "Check which secure-coding baseline Claude Code loaded.",
}


class ReadmeRenderError(ValueError):
    """The packaged metadata cannot produce an accurate README."""


def _wrap(value: str, *, initial: str = "", subsequent: str = "") -> str:
    return textwrap.fill(
        value,
        width=88,
        initial_indent=initial,
        subsequent_indent=subsequent,
        break_long_words=False,
        break_on_hyphens=False,
    )


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ReadmeRenderError(f"required packaged metadata is missing: {path}") from error
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReadmeRenderError(f"cannot read packaged metadata {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReadmeRenderError(f"packaged metadata must be a JSON object: {path}")
    return value


def _read_profile(path: Path) -> dict[str, Any]:
    try:
        value = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ReadmeRenderError(f"packaged organization profile is missing: {path}") from error
    except (OSError, UnicodeError, yaml.YAMLError) as error:
        raise ReadmeRenderError(f"cannot read packaged organization profile {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReadmeRenderError(f"organization profile must be a YAML mapping: {path}")
    return value


def _safe_text(value: str, *, limit: int = 240) -> str:
    """Turn maintainer-controlled text into one bounded Markdown-safe line."""
    value = " ".join(value.split())
    value = "".join(character for character in value if character.isprintable())
    value = html.escape(value.replace("`", "'"), quote=False)
    if len(value) > limit:
        value = value[: limit - 1].rstrip() + "…"
    return value


def _required_text(mapping: dict[str, Any], field: str, *, limit: int = 240) -> str:
    value = mapping.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ReadmeRenderError(f"organization.{field} must be a non-empty string")
    return _safe_text(value, limit=limit)


def _validated_names(value: Any, field: str) -> set[str]:
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ReadmeRenderError(f"{field} must be a list of names")
    names = set(value)
    if len(names) != len(value):
        raise ReadmeRenderError(f"{field} contains duplicate names")
    invalid = sorted(name for name in names if not SURFACE_NAME_PATTERN.fullmatch(name))
    if invalid:
        raise ReadmeRenderError(f"{field} contains invalid names: {', '.join(invalid)}")
    return names


def _safe_url(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or len(value) > 2048:
        raise ReadmeRenderError(f"{field} must be a non-empty URL or null")
    if any(
        character.isspace() or not character.isprintable() or character in "`<>"
        for character in value
    ):
        raise ReadmeRenderError(f"{field} contains unsafe whitespace or delimiters")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise ReadmeRenderError(f"{field} must be an HTTPS URL without credentials")
    return value


def _disabled_skills(config: dict[str, Any], included: set[str]) -> set[str]:
    toggles = config.get("skill_toggles", {})
    if not isinstance(toggles, dict):
        raise ReadmeRenderError("config.json skill_toggles must be an object")
    disabled: set[str] = set()
    for name, toggle in toggles.items():
        if not isinstance(name, str) or not SURFACE_NAME_PATTERN.fullmatch(name):
            raise ReadmeRenderError("config.json contains an invalid skill toggle name")
        if not isinstance(toggle, dict) or not isinstance(toggle.get("enabled"), bool):
            raise ReadmeRenderError(f"skill toggle for {name!r} must contain boolean enabled")
        if name in included and not toggle["enabled"]:
            disabled.add(name)
    return disabled


def _skill_description(plugin_root: Path, name: str) -> str:
    if name in COMMAND_DESCRIPTIONS:
        return COMMAND_DESCRIPTIONS[name]
    path = plugin_root / "skills" / name / "SKILL.md"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise ReadmeRenderError(f"cannot read included skill {path}: {error}") from error
    if not lines or lines[0].strip() != "---":
        raise ReadmeRenderError(f"included skill has no YAML frontmatter: {path}")
    try:
        end = lines.index("---", 1)
        frontmatter = yaml.safe_load("\n".join(lines[1:end]))
    except (ValueError, yaml.YAMLError) as error:
        raise ReadmeRenderError(f"invalid YAML frontmatter in {path}: {error}") from error
    if not isinstance(frontmatter, dict) or frontmatter.get("name") != name:
        raise ReadmeRenderError(f"skill name mismatch in {path}: expected {name!r}")
    description = frontmatter.get("description")
    if not isinstance(description, str) or not description.strip():
        raise ReadmeRenderError(f"skill description is missing in {path}")
    description = re.split(r"(?<=[.!?])\s+", description, maxsplit=1)[0]
    return _safe_text(description)


def _ordered_skills(included: set[str]) -> list[str]:
    public = included - INTERNAL_SKILLS
    ordered = [name for name in PREFERRED_ORDER if name in public]
    ordered.extend(sorted(public - set(ordered)))
    return ordered


def _core_build(manifest: dict) -> str:
    """Name the upstream implementation this package was built from.

    A branch build reuses the upstream version string across many commits, so
    the recorded ref and commit are what identify the build exactly.
    """
    core_version = manifest.get("appsec_advisor_core_version")
    if core_version is None:
        return ""
    if not isinstance(core_version, str) or not VERSION_PATTERN.fullmatch(core_version):
        raise ReadmeRenderError("plugin.json contains an invalid upstream core version")

    origin = []
    for key, pattern, length in (
        ("appsec_advisor_core_ref", CORE_REF_PATTERN, None),
        ("appsec_advisor_core_commit", CORE_COMMIT_PATTERN, 12),
    ):
        value = manifest.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not pattern.fullmatch(value):
            raise ReadmeRenderError(f"plugin.json contains an invalid {key}")
        origin.append(value[:length] if length else value)

    if origin:
        return f"{core_version} ({' @ '.join(origin)})"
    return core_version


def render_readme(plugin_root: Path) -> Path:
    plugin_root = plugin_root.resolve()
    metadata_root = plugin_root / ".claude-plugin"
    manifest = _read_json(metadata_root / "plugin.json")
    surface = _read_json(metadata_root / "package-surface.json")
    config = _read_json(plugin_root / "config.json")
    profile = _read_profile(plugin_root / "org-profile" / "org-profile.yaml")

    plugin_name = manifest.get("name")
    version = manifest.get("version")
    if not isinstance(plugin_name, str) or not PLUGIN_NAME_PATTERN.fullmatch(plugin_name):
        raise ReadmeRenderError("plugin.json contains an invalid plugin name")
    if not isinstance(version, str) or not VERSION_PATTERN.fullmatch(version):
        raise ReadmeRenderError("plugin.json contains an invalid plugin version")

    organization = profile.get("organization")
    if not isinstance(organization, dict):
        raise ReadmeRenderError("organization profile has no organization mapping")
    org_name = _required_text(organization, "name")
    owner = _required_text(organization, "owner")

    if surface.get("version") != 1:
        raise ReadmeRenderError("unsupported or invalid package-surface.json")
    skills_block = surface.get("skills")
    hooks_block = surface.get("hooks")
    if not isinstance(skills_block, dict) or not isinstance(hooks_block, dict):
        raise ReadmeRenderError("package surface must contain skills and hooks objects")
    included = _validated_names(skills_block.get("included"), "skills.included")
    hooks = _validated_names(hooks_block.get("included"), "hooks.included")
    if "help" not in included or "create-threat-model" not in included:
        raise ReadmeRenderError("package surface must include help and create-threat-model")
    disabled = _disabled_skills(config, included)

    banner = config.get("banner", {})
    if not isinstance(banner, dict):
        raise ReadmeRenderError("config.json banner must be an object")
    banner_enabled = banner.get("enabled", True)
    if not isinstance(banner_enabled, bool):
        raise ReadmeRenderError("config.json banner.enabled must be boolean")
    startup_status = banner_enabled and "session-banner" in hooks
    info_url = _safe_url(banner.get("url"), "config.json banner.url")

    baseline = config.get("baseline", {})
    if not isinstance(baseline, dict):
        raise ReadmeRenderError("config.json baseline must be an object")
    baseline_enabled = baseline.get("enabled", True)
    if not isinstance(baseline_enabled, bool):
        raise ReadmeRenderError("config.json baseline.enabled must be boolean")
    baseline_name = baseline.get("name", "AI Secure Coding Baseline")
    baseline_id = baseline.get("id")
    if not isinstance(baseline_name, str) or not baseline_name.strip():
        raise ReadmeRenderError("config.json baseline.name must be a non-empty string")
    baseline_name = _safe_text(baseline_name)
    if baseline_id is not None and (not isinstance(baseline_id, str) or not baseline_id.strip()):
        raise ReadmeRenderError("config.json baseline.id must be a non-empty string or null")
    baseline_label = baseline_name
    if isinstance(baseline_id, str):
        baseline_label += f" (`{_safe_text(baseline_id, limit=120)}`)"

    quick_commands = [f"/{plugin_name}:help"]
    if "check-permissions" in included and "check-permissions" not in disabled:
        quick_commands.append(f"/{plugin_name}:check-permissions --update")
    quick_commands.append(f"/{plugin_name}:create-threat-model")
    quick_block = "\n".join(quick_commands)

    startup_paragraph = ""
    if startup_status:
        startup_paragraph = "\n" + _wrap(
            "When the plugin loads, you should see its startup status: the package "
            "version, the current threat-model state, and—when configured—the "
            f"secure-coding baseline state. If neither that status nor `/{plugin_name}:help` "
            "is available, the plugin probably has not loaded."
        )
        startup_paragraph += "\n"

    value_items = [
        "Create an architecture-focused threat model while the design context is still fresh.",
        "Revisit findings and remediation work as the repository changes.",
    ]
    available = included - disabled
    if {"audit-security-requirements", "verify-requirements"} & available:
        value_items.append("Check code and changes against the security requirements selected by our AppSec team.")
    value_list = "\n".join(_wrap(item, initial="- ", subsequent="  ") for item in value_items)

    workflow_actions = [
        ("create-threat-model", "Create the first threat model for the repository."),
        ("update-threat-model", "Update it after relevant design or code changes."),
        ("show-threat-model", "Inspect the current findings, backlog, and coverage."),
        ("review-threat-model", "Triage findings and remediation decisions."),
    ]
    available_workflow = [
        (name, description) for name, description in workflow_actions if name in available
    ]
    workflow_lines = [
        _wrap(description, initial=f"{index}. ", subsequent="   ")
        for index, (_, description) in enumerate(available_workflow, start=1)
    ]
    workflow_section = ""
    if len(workflow_lines) > 1:
        workflow_section = (
            "\n## Normal workflow\n\n"
            + "\n".join(workflow_lines)
            + f"\n\nUse `/{plugin_name}:help` when your package offers a different workflow.\n"
        )

    if baseline_enabled:
        baseline_lines = [
            _wrap(
                f"This package expects {baseline_label}. It is not another scanner. It is a "
                "set of secure-coding rules that Claude Code should load before it writes or "
                "changes code. The rules provide consistent guardrails at the point where "
                "implementation decisions are made."
            )
        ]
        if startup_status:
            baseline_lines.extend(
                [
                    "",
                    _wrap("The startup status tells you whether the expected baseline was found and loaded."),
                ]
            )
        baseline_actions: list[str] = []
        if "verify-baseline" in included and "verify-baseline" not in disabled:
            baseline_actions.append(f"`/{plugin_name}:verify-baseline`")
        if "install-baseline" in included and "install-baseline" not in disabled:
            baseline_actions.append(f"`/{plugin_name}:install-baseline`")
        if baseline_actions:
            baseline_lines.append(_wrap(f"Use {' or '.join(baseline_actions)} if it needs attention."))
        else:
            baseline_lines.append(
                _wrap(f"If it needs attention, contact {owner} for the approved installation path.")
            )
        baseline_section = "\n".join(baseline_lines)
    else:
        baseline_section = _wrap(
            "No secure-coding baseline is configured in this package. "
            f"Ask {owner} if your project should use one."
        )

    command_rows = []
    for name in _ordered_skills(included):
        status = "Disabled" if name in disabled else "Available"
        command_rows.append(
            f"| `/{plugin_name}:{name}` | {status} | {_skill_description(plugin_root, name)} |"
        )
    commands_table = "\n".join(command_rows)

    more_information = ""
    if info_url:
        more_information = (
            f"\nMore information: [Internal AppSec information](<{info_url}>)\n"
        )

    upstream_url = _safe_url(surface.get("upstream_url"), "package-surface.json upstream_url")
    core_build = _core_build(manifest)
    upstream_reference = ""
    if upstream_url or core_build:
        upstream = (
            f"[appsec-advisor](<{upstream_url.removesuffix('.git')}>)"
            if upstream_url
            else "appsec-advisor"
        )
        built_from = f" {core_build}" if core_build else ""
        upstream_reference = (
            f"\nThis internal package is based on {upstream}{built_from}.\n"
        )

    identity_paragraph = _wrap(
        f"`{plugin_name} {version}` is maintained by {owner} for developers at {org_name}."
    )
    help_paragraph = _wrap(
        f"`/{plugin_name}:help` is the package-specific reference. It shows only the "
        f"commands included by {owner} and marks commands that are currently disabled."
    )
    support_paragraph = _wrap(
        f"Start with `/{plugin_name}:status` for run state when that command is available, "
        f"or `/{plugin_name}:help` to find the right diagnostic command. When contacting "
        f"{owner}, include the command, selected preset, and non-sensitive part of the "
        "error. Do not send credentials, tokens, source code, or complete analysis "
        "artifacts through a channel that is not approved for that data."
    )

    output = f"""# {plugin_name}

{identity_paragraph}
It brings our threat-modeling workflow and security guardrails into Claude Code,
close to the design and code they are meant to support.

Use it for a new service, a significant change, release preparation, or when an
existing threat model no longer reflects the code. It supports engineering and
AppSec review; it does not replace either one.

## Start here

Open Claude Code in the repository you want to review and load the plugin through
your organization's approved release or Marketplace. If you are testing a local
build, use `claude --plugin-dir /absolute/path/to/build/{plugin_name}`.
{startup_paragraph}
Then run:

```text
{quick_block}
```

{help_paragraph}
{workflow_section}

## What it helps with

{value_list}

Start with the normal threat-model command unless you have a reason to choose a
different depth. The analysis can take several minutes; review its evidence and
findings before using them for a release or risk decision.

## AI Secure Coding Baseline

{baseline_section}

## Commands in this package

| Command | Status | When to use it |
|---|---|---|
{commands_table}

For flags and examples, use `/{plugin_name}:help` and then the relevant command's
`--help` option.

## Help and feedback

{support_paragraph}
{more_information}{upstream_reference}"""

    destination = plugin_root / "README.md"
    temporary_name = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=destination.parent, delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(output)
            temporary.flush()
            os.fchmod(temporary.fileno(), 0o644)
        os.replace(temporary_name, destination)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return destination


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-root", type=Path, required=True)
    args = parser.parse_args()
    try:
        destination = render_readme(args.plugin_root)
    except ReadmeRenderError as error:
        parser.error(str(error))
    print(f"Packaged README generated: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
