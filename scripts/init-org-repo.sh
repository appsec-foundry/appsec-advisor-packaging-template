#!/usr/bin/env bash
# Creates a fresh org packaging repo for appsec-advisor.
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
# Or locally: scripts/init-org-repo.sh
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: this initializer requires Bash; run it with: bash scripts/init-org-repo.sh" >&2
  exit 2
fi
if [ "${BASH_VERSINFO[0]}" -lt 3 ] || \
   { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "ERROR: Bash 3.2 or newer is required; found ${BASH_VERSION}." >&2
  exit 2
fi
set -euo pipefail

TMPDIR_CLONE=""
CANDIDATE_DIR=""

cleanup() {
  if [ -n "${TMPDIR_CLONE}" ]; then
    rm -rf -- "${TMPDIR_CLONE}"
  fi
  if [ -n "${CANDIDATE_DIR}" ]; then
    rm -rf -- "${CANDIDATE_DIR}"
  fi
}
trap cleanup EXIT

# ── Helpers ──────────────────────────────────────────────────────────────────

check_prerequisites() {
  local dependency missing=""
  for dependency in git python3 make sed mktemp; do
    if ! command -v "${dependency}" >/dev/null 2>&1; then
      missing="${missing} ${dependency}"
    fi
  done
  if [ -n "${missing}" ]; then
    echo "ERROR: missing required commands:${missing}" >&2
    echo "Install them and rerun this setup. Required: git, Python 3.10+, make, sed, and mktemp." >&2
    exit 2
  fi

  if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
    echo "ERROR: Python 3.10 or newer is required; found $(python3 --version 2>&1)." >&2
    exit 2
  fi
}

check_build_python_modules() {
  local missing
  if ! missing="$(python3 -c '
import importlib.util

required = {"yaml": "PyYAML", "jsonschema": "jsonschema"}
print(" ".join(package for module, package in required.items() if importlib.util.find_spec(module) is None))
')"; then
    echo "ERROR: could not inspect the Python environment required for the optional plugin build." >&2
    echo "Activate a working Python 3.10+ environment, then run: make package" >&2
    return 1
  fi
  if [ -n "${missing}" ]; then
    echo "ERROR: the optional plugin build needs these Python packages: ${missing}" >&2
    echo "Create or activate a Python 3.10+ environment containing them, then run: make package" >&2
    echo "CI installs the reviewed versions from ci-requirements.lock." >&2
    return 1
  fi
}

valid_organization_id() {
  case "$1" in
    ""|[!a-z0-9]*|*[!a-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_plugin_name() {
  case "$1" in
    ""|[!a-z0-9]*|*[!a-z0-9-]*) return 1 ;;
    *) return 0 ;;
  esac
}

uppercase_ascii() {
  PYTHONUTF8=1 python3 - "$1" <<'PY'
import sys

print(sys.argv[1].upper())
PY
}

check_template_layout() {
  local relative missing=""
  for relative in \
    Makefile \
    .gitignore \
    AGENTS.md \
    README.example.md \
    docs/MAINTAINER-RUNBOOK.example.md \
    scripts/fetch-upstream.sh \
    scripts/upstream-check.sh \
    scripts/select-latest-release.py \
    scripts/check-org-hook-collisions.py \
    scripts/package-local.sh \
    scripts/release.sh \
    org-profile/org-profile.yaml \
    org-profile/package-policy.yaml \
    org-profile/hooks/guard.py \
    ci-templates/github/workflows/package.yml \
    ci-templates/gitlab-ci.yml; do
    if [ ! -f "${TEMPLATE_BASE}/${relative}" ]; then
      missing="${missing} ${relative}"
    fi
  done
  if [ -n "${missing}" ]; then
    echo "ERROR: packaging template is incomplete; missing:${missing}" >&2
    echo "Use a complete template checkout or verify APPSEC_ADVISOR_TEMPLATE_REF." >&2
    exit 2
  fi
}

normalize_utf8() {
  PYTHONUTF8=1 python3 -c '
import sys
import unicodedata

try:
    value = sys.stdin.buffer.read().decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(2)
sys.stdout.write(unicodedata.normalize("NFC", value))
'
}

ask() {
  local prompt="$1" default="${2:-}"
  local reply value normalized
  while true; do
    if [ -n "${default}" ]; then
      read -r -p "${prompt} [${default}]: " reply
      value="${reply:-${default}}"
    else
      read -r -p "${prompt}: " reply
      if [ -z "${reply}" ]; then
        echo "  (required)" >&2
        continue
      fi
      value="${reply}"
    fi
    if normalized=$(printf '%s' "${value}" | normalize_utf8); then
      printf '%s\n' "${normalized}"
      return 0
    fi
    echo "  (invalid UTF-8 input — please enter the value again)" >&2
  done
}

valid_package_version() {
  PYTHONUTF8=1 python3 - "$1" <<'PY'
import re
import sys

version = sys.argv[1]
identifier = r"[0-9A-Za-z-]+"
pattern = re.compile(
    rf"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    rf"(?:-({identifier}(?:\.{identifier})*))?"
    rf"(?:\+({identifier}(?:\.{identifier})*))?$"
)
match = pattern.fullmatch(version)
if not match:
    raise SystemExit(2)
prerelease = match.group(4)
if prerelease and any(
    part.isdigit() and len(part) > 1 and part.startswith("0")
    for part in prerelease.split(".")
):
    raise SystemExit(2)
PY
}

ask_package_version() {
  local version
  while true; do
    version="$(ask "Plugin package version (shown in the banner)" "0.1.0")"
    if valid_package_version "${version}"; then
      printf '%s\n' "${version}"
      return 0
    fi
    echo "  (enter a valid SemVer such as 1.2.0 or 1.2.0-internal.1)" >&2
  done
}

valid_upstream_ref() {
  case "$1" in
    ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._/+@%-]*) return 1 ;;
  esac
  git check-ref-format "refs/appsec-advisor/$1" >/dev/null 2>&1
}

resolve_latest_upstream_release() {
  local upstream_url latest
  upstream_url="${APPSEC_ADVISOR_URL:-https://github.com/appsec-foundry/appsec-advisor.git}"

  if ! latest="$(git ls-remote --tags --refs "${upstream_url}" 'v[0-9]*' | \
      PYTHONUTF8=1 python3 "${TEMPLATE_BASE}/scripts/select-latest-release.py")"; then
    echo "ERROR: could not list appsec-advisor releases from the configured APPSEC_ADVISOR_URL." >&2
    echo "Check network access and APPSEC_ADVISOR_URL, then retry." >&2
    return 2
  fi
  if [ -z "${latest}" ]; then
    echo "ERROR: no valid v* SemVer appsec-advisor release tags were found at the configured APPSEC_ADVISOR_URL." >&2
    echo "Choose the development channel or set APPSEC_ADVISOR_REF explicitly." >&2
    return 2
  fi
  printf '%s\n' "${latest}"
}

select_upstream_ref() {
  local configured reply
  configured="${APPSEC_ADVISOR_REF:-}"
  if [ -n "${configured}" ]; then
    if [ "${configured}" = latest ]; then
      printf '%s\n' latest
      return 0
    fi
    if ! valid_upstream_ref "${configured}"; then
      echo "ERROR: APPSEC_ADVISOR_REF is not a valid tag or branch name: ${configured}" >&2
      return 2
    fi
    printf '%s\n' "${configured}"
    return 0
  fi

  while true; do
    echo "Select the appsec-advisor upstream channel:" >&2
    echo "  1. Latest stable release, pinned to the resolved tag (default)" >&2
    echo "  2. Development branch 'dev', updated on every build" >&2
    read -r -p "Upstream channel [1]: " reply || reply=""
    case "${reply}" in
      ""|1|stable|Stable)
        printf '%s\n' latest
        return 0
        ;;
      2|dev|Dev)
        printf '%s\n' dev
        return 0
        ;;
      *) echo "  (enter 1 for stable or 2 for dev)" >&2 ;;
    esac
  done
}

normalize_optional_https_url() {
  PYTHONUTF8=1 python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1].strip()
if not value:
    print("")
    raise SystemExit(0)
if len(value) > 2048 or any(
    character.isspace() or not character.isprintable() or character in "#$'\"`<>\\|"
    for character in value
):
    raise SystemExit(2)
try:
    parsed = urlsplit(value)
except ValueError:
    raise SystemExit(2)
if (
    parsed.scheme != "https"
    or not parsed.hostname
    or parsed.username is not None
    or parsed.password is not None
):
    raise SystemExit(2)
print(value)
PY
}

ask_optional_https_url() {
  local prompt="$1" reply normalized
  while true; do
    read -r -p "${prompt} (optional; HTTPS): " reply || reply=""
    if normalized=$(normalize_optional_https_url "${reply}"); then
      printf '%s\n' "${normalized}"
      return 0
    fi
    echo "  (enter an HTTPS URL without credentials, whitespace, fragments, or shell metacharacters; or leave empty)" >&2
  done
}

initials() {
  PYTHONUTF8=1 python3 - "$1" <<'PY'
import sys
import unicodedata

latin_fallbacks = str.maketrans({
    "ø": "o", "æ": "ae", "œ": "oe", "ð": "d", "þ": "th",
    "ł": "l", "đ": "d", "ħ": "h", "ı": "i", "ŋ": "n", "ŧ": "t",
})
name = sys.argv[1].casefold().translate(latin_fallbacks)
name = unicodedata.normalize("NFKD", name)
ascii_name = name.encode("ascii", "ignore").decode("ascii")
words = ascii_name.translate(str.maketrans({c: " " for c in "+&/., -"})).split()
print("".join(word[0] for word in words))
PY
}

# Escape a string for safe use as a sed replacement (escapes & \ and /).
sed_escape() {
  printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

# JSON string syntax is valid YAML string syntax. Encoding profile values this
# way preserves Unicode and prevents characters such as ':' or '#' from
# changing the YAML structure.
yaml_quote() {
  PYTHONUTF8=1 python3 -c '
import json
import sys

value = sys.stdin.buffer.read().decode("utf-8")
sys.stdout.write(json.dumps(value, ensure_ascii=False))
'
}

validate_utf8_file() {
  PYTHONUTF8=1 python3 - "$1" "${2:-report}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
try:
    path.read_bytes().decode("utf-8")
except UnicodeDecodeError as error:
    if sys.argv[2] != "quiet":
        print(
            f"ERROR: {path} is not valid UTF-8 at byte {error.start}. "
            "Repair or replace this user-owned file before building.",
            file=sys.stderr,
        )
    raise SystemExit(2)
PY
}

migrate_package_policy() {
  PYTHONUTF8=1 python3 - "$1" "$2" <<'PY'
from pathlib import Path
import os
import re
import stat
import sys
import tempfile

policy_path = Path(sys.argv[1])
profile_path = Path(sys.argv[2])


def read_utf8(path: Path, *, keepends: bool = False) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines(keepends=keepends)
    except UnicodeDecodeError as error:
        print(
            f"ERROR: {path} is not valid UTF-8 at byte {error.start}",
            file=sys.stderr,
        )
        raise SystemExit(2)


lines = read_utf8(policy_path, keepends=True)
profile_lines = read_utf8(profile_path)


def selection_block(section: str) -> tuple[str | None, int | None]:
    section_pattern = re.compile(rf"^  {re.escape(section)}:\s*(?:#.*)?$")
    section_start = next(
        (index for index, line in enumerate(lines) if section_pattern.match(line.rstrip("\r\n"))),
        None,
    )
    if section_start is None:
        raise ValueError(f"plugin_surface.{section} is missing")
    section_end = next(
        (
            index
            for index in range(section_start + 1, len(lines))
            if re.match(r"^  [A-Za-z0-9_-]+:", lines[index])
        ),
        len(lines),
    )
    selections = []
    for mode in ("include", "exclude"):
        pattern = re.compile(rf"^    {mode}:\s*(?:#.*)?$")
        index = next(
            (
                index
                for index in range(section_start + 1, section_end)
                if pattern.match(lines[index].rstrip("\r\n"))
            ),
            None,
        )
        if index is not None:
            selections.append((mode, index))
    if len(selections) > 1:
        raise ValueError(f"plugin_surface.{section} defines include and exclude")
    return selections[0] if selections else (None, None)


def add_mcp_allowlist(entries: list[str]) -> bool:
    section_pattern = re.compile(r"^  mcp_servers:\s*(?:#.*)?$")
    if any(section_pattern.match(line.rstrip("\r\n")) for line in lines):
        return False
    surface_start = next(
        (
            index
            for index, line in enumerate(lines)
            if re.match(r"^plugin_surface:\s*(?:#.*)?$", line.rstrip("\r\n"))
        ),
        None,
    )
    if surface_start is None:
        raise ValueError("plugin_surface is missing")
    insertion = next(
        (
            index
            for index in range(surface_start + 1, len(lines))
            if lines[index].strip() and not lines[index][0].isspace()
        ),
        len(lines),
    )
    block = ["  mcp_servers:\n", "    include:\n"]
    block.extend(f"      - {entry}\n" for entry in sorted(set(entries)))
    lines[insertion:insertion] = block
    return True


def ensure_available(section: str, entry: str) -> bool:
    mode, selection = selection_block(section)
    if mode is None or selection is None:
        return False
    item_pattern = re.compile(rf"^      -\s+{re.escape(entry)}\s*(?:#.*)?$")
    end = next(
        (
            index
            for index in range(selection + 1, len(lines))
            if lines[index].strip()
            and not lines[index].lstrip().startswith("#")
            and len(lines[index]) - len(lines[index].lstrip(" ")) <= 4
        ),
        len(lines),
    )
    matches = [
        index
        for index in range(selection + 1, end)
        if item_pattern.match(lines[index].rstrip("\r\n"))
    ]
    if mode == "include":
        if matches:
            return False
        lines.insert(selection + 1, f"      - {entry}\n")
        return True
    for index in reversed(matches):
        del lines[index]
    return bool(matches)


def ensure_unavailable(section: str, entry: str) -> bool:
    mode, selection = selection_block(section)
    if mode is None or selection is None:
        return False
    item_pattern = re.compile(rf"^      -\s+{re.escape(entry)}\s*(?:#.*)?$")
    end = next(
        (
            index
            for index in range(selection + 1, len(lines))
            if lines[index].strip()
            and not lines[index].lstrip().startswith("#")
            and len(lines[index]) - len(lines[index].lstrip(" ")) <= 4
        ),
        len(lines),
    )
    matches = [
        index
        for index in range(selection + 1, end)
        if item_pattern.match(lines[index].rstrip("\r\n"))
    ]
    if mode == "include":
        for index in reversed(matches):
            del lines[index]
        return bool(matches)
    if matches:
        return False
    lines.insert(selection + 1, f"      - {entry}\n")
    return True


banner_disabled = False
inside_banner = False
mcp_server_names = []
inside_mcp = False
inside_mcp_servers = False
for line in profile_lines:
    if line and not line[0].isspace():
        top_level = line.split(":", 1)[0]
        inside_banner = top_level == "banner"
        inside_mcp = top_level == "mcp"
        inside_mcp_servers = False
        continue
    if inside_banner and re.match(r"^  enabled:\s*false(?:\s+#.*)?$", line):
        banner_disabled = True
    if inside_mcp and re.match(r"^  servers:\s*(?:#.*)?$", line):
        inside_mcp_servers = True
        continue
    if inside_mcp_servers:
        server = re.match(r"^    ([a-z0-9][a-z0-9_-]{0,62}):\s*(?:#.*)?$", line)
        if server:
            mcp_server_names.append(server.group(1))
        elif line.strip() and len(line) - len(line.lstrip(" ")) <= 2:
            inside_mcp_servers = False

enabled = []
disabled = []
added_surfaces = []
try:
    if ensure_available("skills", "help"):
        enabled.append("help")
    if banner_disabled and ensure_unavailable("hooks", "session-banner"):
        disabled.append("session-banner")
    if add_mcp_allowlist(mcp_server_names):
        added_surfaces.append("mcp_servers allowlist")
except ValueError as error:
    print(f"ERROR: cannot migrate package policy: {error}", file=sys.stderr)
    raise SystemExit(2)

if enabled or disabled or added_surfaces:
    mode = stat.S_IMODE(policy_path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=policy_path.parent, prefix=f".{policy_path.name}."
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as temporary:
            temporary.writelines(lines)
        os.chmod(temporary_name, mode)
        os.replace(temporary_name, policy_path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    changes = []
    if enabled:
        changes.append(f"enabled {', '.join(enabled)}")
    if disabled:
        changes.append(f"disabled {', '.join(disabled)}")
    if added_surfaces:
        changes.append(f"added {', '.join(added_surfaces)}")
    print(f"  migrated: {policy_path} ({'; '.join(changes)})")
PY
}

# ── Intro ─────────────────────────────────────────────────────────────────────

echo ""
echo "appsec-advisor — org packaging repo setup"
echo "────────────────────────────────────────────"
echo "This script creates a ready-to-use packaging repo for appsec-advisor."
echo "It asks for organization settings, creates a local Git commit, and can build"
echo "the first plugin package. It does not push or install anything."
echo ""
echo "==> Checking prerequisites …"
check_prerequisites
echo "Prerequisites OK: git, Python 3.10+, make, sed, mktemp"
echo ""

# ── Gather input ─────────────────────────────────────────────────────────────

REINIT_MODE=false
if [ -n "${APPSEC_REINIT_TARGET:-}" ]; then
  REINIT_MODE=true
  TARGET_DIR="${APPSEC_REINIT_TARGET}"
  ORG_NAME="$(printf '%s' "${APPSEC_REINIT_ORG_NAME:?}" | normalize_utf8)"
  ORG_ID="${APPSEC_REINIT_ORG_ID:?}"
  PLUGIN_NAME="${APPSEC_REINIT_PLUGIN_NAME:?}"
  # Reinit wrappers generated before organization-owned versions existed do
  # not pass this value. Give those existing repositories the new default.
  PACKAGE_VERSION="${APPSEC_REINIT_PACKAGE_VERSION:-0.1.0}"
  valid_package_version "${PACKAGE_VERSION}" || {
    echo "ERROR: existing plugin package version is not valid SemVer: ${PACKAGE_VERSION}" >&2
    exit 2
  }
  # New reinit wrappers preserve this value from the existing Makefile. Older
  # wrappers fall back to an explicit caller override or the historical pin.
  UPSTREAM_REF="${APPSEC_REINIT_UPSTREAM_REF:-${APPSEC_ADVISOR_REF:-v0.6.0-beta.1}}"
  if ! valid_upstream_ref "${UPSTREAM_REF}"; then
    echo "ERROR: existing APPSEC_ADVISOR_REF is not a valid tag or branch name: ${UPSTREAM_REF}" >&2
    exit 2
  fi
  OWNER="$(printf '%s' "${APPSEC_REINIT_OWNER:?}" | normalize_utf8)"
  DEMO_CONTENT="${APPSEC_REINIT_DEMO:?}"
  BASELINE_ENABLED="${APPSEC_REINIT_BASELINE:?}"
  # Older reinit wrappers do not carry this setting; preserve the historical
  # default-on behavior for those repositories.
  STATUSLINE_ENABLED="${APPSEC_REINIT_STATUSLINE:-true}"
  INTERNAL_REPOSITORY_URL="${APPSEC_REINIT_REPOSITORY_URL:-}"
  if ! INTERNAL_REPOSITORY_URL=$(normalize_optional_https_url "${INTERNAL_REPOSITORY_URL}"); then
    echo "ERROR: existing INTERNAL_REPOSITORY_URL must be an HTTPS URL without credentials or shell metacharacters" >&2
    exit 2
  fi
  if ! valid_organization_id "${ORG_ID}"; then
    echo "ERROR: existing organization id must start with a lowercase letter or digit and contain only lowercase letters, digits, '.', '_' and '-': ${ORG_ID}" >&2
    exit 2
  fi
  if ! valid_plugin_name "${PLUGIN_NAME}"; then
    echo "ERROR: existing plugin name must start with a lowercase letter or digit and contain only lowercase letters, digits and '-': ${PLUGIN_NAME}" >&2
    exit 2
  fi
  OWNER_PREFIX="$(uppercase_ascii "${ORG_ID}")"
else
  ORG_NAME=$(ask "Organization name (e.g. Acme Corp)")
  ORG_ID=$(initials "${ORG_NAME}")
  while true; do
    ORG_ID=$(ask "Organization id (short lowercase abbreviation, e.g. 'acme', 'hl' — used in plugin name)" "${ORG_ID}")
    if valid_organization_id "${ORG_ID}"; then
      break
    fi
    echo "  (start with a lowercase letter or digit; use only lowercase letters, digits, '.', '_' and '-')" >&2
  done
  while true; do
    PLUGIN_NAME=$(ask "Plugin name (Claude Code command prefix)" "${ORG_ID}-appsec")
    if valid_plugin_name "${PLUGIN_NAME}"; then
      break
    fi
    echo "  (start with a lowercase letter or digit; use only lowercase letters, digits and '-')" >&2
  done
  PACKAGE_VERSION=$(ask_package_version)
  OWNER_PREFIX="$(uppercase_ascii "${ORG_ID}")"
  OWNER=$(ask "Team owner (e.g. AppSec Team)" "${OWNER_PREFIX} AppSec Team")
  TARGET_DIR=$(ask "Target directory" "./${ORG_ID}-appsec-advisor")

  UPSTREAM_REF="$(select_upstream_ref)" || exit 2

  read -r -p "Include demo content (example requirements + filled org profile)? [y/N]: " _demo_reply
  case "${_demo_reply}" in
    [yY]*) DEMO_CONTENT=true ;;
    *)     DEMO_CONTENT=false ;;
  esac

  read -r -p "Include the AI Secure Coding Baseline? [Y/n] (change later in org-profile/org-profile.yaml): " _baseline_reply || _baseline_reply=""
  case "${_baseline_reply}" in
    [nN]*) BASELINE_ENABLED=false ;;
    *)     BASELINE_ENABLED=true ;;
  esac

  read -r -p "Show plugin and security status when Claude Code starts? [Y/n] (change later in org-profile and package-policy): " _statusline_reply || _statusline_reply=""
  case "${_statusline_reply}" in
    [nN]*) STATUSLINE_ENABLED=false ;;
    *)     STATUSLINE_ENABLED=true ;;
  esac

  INTERNAL_REPOSITORY_URL=$(ask_optional_https_url "Internal packaging repository URL")
fi

if python3 - "${TARGET_DIR}" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1]).resolve(strict=False)
raise SystemExit(0 if target == Path(target.anchor) else 1)
PY
then
  echo "ERROR: refusing to use a filesystem root as the target directory: ${TARGET_DIR}" >&2
  exit 2
fi

echo ""

# ── Source files ──────────────────────────────────────────────────────────────

# Resolve absolute path so relative-path invocations work correctly.
SCRIPT_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")" || true
TEMPLATE_BASE="${SCRIPT_ABS%/scripts/init-org-repo.sh}"
TEMPLATE_REF="${APPSEC_ADVISOR_TEMPLATE_REF:-main}"

# When invoked via curl/pipe the path above resolves to something like /dev/fd/N
# which has no Makefile — fall back to cloning.
if [ ! -f "${TEMPLATE_BASE}/Makefile" ]; then
  TMPDIR_CLONE="$(mktemp -d)"
  echo "==> Cloning template from GitHub …"
  if ! git clone --depth 1 --branch "${TEMPLATE_REF}" \
      "https://github.com/appsec-foundry/appsec-advisor-packaging-template.git" \
      "${TMPDIR_CLONE}"; then
    echo "ERROR: could not fetch packaging template ref '${TEMPLATE_REF}'." >&2
    echo "Check network access and APPSEC_ADVISOR_TEMPLATE_REF, then retry." >&2
    exit 2
  fi
  TEMPLATE_BASE="${TMPDIR_CLONE}"
fi
check_template_layout

if [ "${REINIT_MODE}" != true ] && [ "${UPSTREAM_REF}" = latest ]; then
  UPSTREAM_REF="$(resolve_latest_upstream_release)" || exit 2
  echo "==> Latest stable appsec-advisor release: ${UPSTREAM_REF} (pinned)"
fi

# ── Create repo ───────────────────────────────────────────────────────────────

REINIT=false
if [ "${REINIT_MODE}" = true ]; then
  if [ ! -d "${TARGET_DIR}" ]; then
    echo "ERROR: reinitialization target is not a directory: ${TARGET_DIR}" >&2
    exit 2
  fi
  REINIT=true
  echo "==> Re-initializing existing packaging repository: ${TARGET_DIR}"
elif [ -e "${TARGET_DIR}" ] && [ ! -d "${TARGET_DIR}" ]; then
  echo "ERROR: target exists but is not a directory: ${TARGET_DIR}" >&2
  exit 2
elif [ -e "${TARGET_DIR}" ]; then
  echo ""
  echo "Warning: '${TARGET_DIR}' already exists."
  echo "  Infrastructure files (Makefile, scripts/, ci-templates/, .gitignore)"
  echo "  will be updated. User-editable files that differ from the new template"
  echo "  (org-profile/, org-skills/, README.md, AGENTS.md) will be offered individually."
  echo "  Required package-policy entries may be reconciled."
  read -r -p "Re-initialize? [y/N]: " confirm
  case "${confirm}" in
    [yY]*) REINIT=true ;;
    *) echo "Aborted."; exit 1 ;;
  esac
  echo ""
fi

if [ "${REINIT}" != true ] && ! git var GIT_AUTHOR_IDENT >/dev/null 2>&1; then
  echo "ERROR: Git author identity is not configured; the initializer creates an initial commit." >&2
  echo "Configure user.name and user.email (globally or for this environment), then rerun." >&2
  exit 2
fi

if [ "${REINIT}" = true ]; then
  echo "For each changed user-editable file: y=overwrite, n=keep,"
  echo "a=overwrite all remaining, k=keep all remaining. The default is n."
  echo "Overwritten files are backed up under ${TARGET_DIR}/.reinit-backups/."
  echo ""
fi

REINIT_FILE_MODE=""
REINIT_BACKUP_RUN=""
REINIT_BACKUP_PATH=""

validate_refresh_target() {
  PYTHONUTF8=1 python3 - "${TARGET_DIR}" "$1" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
target_path = Path(sys.argv[2])
if target_path.is_symlink():
    print(f"ERROR: refusing to replace a symlinked template file: {target_path}", file=sys.stderr)
    raise SystemExit(2)
resolved = target_path.resolve(strict=False)
try:
    resolved.relative_to(root)
except ValueError:
    print(f"ERROR: template file resolves outside the target repository: {target_path}", file=sys.stderr)
    raise SystemExit(2)
PY
}

backup_replaced_file() {
  local source="$1"
  local relative_path="$2"
  local backup_root="${TARGET_DIR}/.reinit-backups"
  local backup_path

  if [ -L "${backup_root}" ] || \
     { [ -e "${backup_root}" ] && [ ! -d "${backup_root}" ]; }; then
    echo "ERROR: recovery backup path is not a regular directory: ${backup_root}" >&2
    exit 2
  fi
  if [ -z "${REINIT_BACKUP_RUN}" ]; then
    REINIT_BACKUP_RUN="${backup_root}/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "${REINIT_BACKUP_RUN}"
    chmod 700 "${backup_root}" "${REINIT_BACKUP_RUN}"
  fi
  backup_path="${REINIT_BACKUP_RUN}/${relative_path}"
  mkdir -p "$(dirname "${backup_path}")"
  cp -p -- "${source}" "${backup_path}"
  REINIT_BACKUP_PATH="${backup_path}"
}

refresh_user_file() {
  local candidate="$1"
  local target="$2"
  local relative_path="$3"
  local answer backup_path

  validate_refresh_target "${target}"
  if [ "${REINIT}" != true ] || [ ! -f "${target}" ]; then
    cp -- "${candidate}" "${target}"
    return 0
  fi
  if cmp -s -- "${candidate}" "${target}"; then
    return 0
  fi

  case "${REINIT_FILE_MODE}" in
    overwrite-all) answer=y ;;
    keep-all) answer=n ;;
    *)
      while true; do
        read -r -p "Template update available for ${relative_path}. Overwrite? [y/N/a=all/k=keep all]: " answer || answer=""
        case "${answer}" in
          [yYnN]|"") break ;;
          [aA]) REINIT_FILE_MODE=overwrite-all; answer=y; break ;;
          [kK]) REINIT_FILE_MODE=keep-all; answer=n; break ;;
          *) echo "  (enter y, n, a, or k)" >&2 ;;
        esac
      done
      ;;
  esac

  case "${answer}" in
    [yY])
      backup_replaced_file "${target}" "${relative_path}"
      backup_path="${REINIT_BACKUP_PATH}"
      cp -- "${candidate}" "${target}"
      echo "  updated: ${target} (backup: ${backup_path})"
      ;;
    *) echo "  kept: ${target}" ;;
  esac
}

CANDIDATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/appsec-reinit-candidates.XXXXXX")"

mkdir -p \
  "${TARGET_DIR}/org-profile/context" \
  "${TARGET_DIR}/org-profile/actors" \
  "${TARGET_DIR}/org-profile/hooks" \
  "${TARGET_DIR}/org-skills" \
  "${TARGET_DIR}/docs" \
  "${TARGET_DIR}/scripts" \
  "${TARGET_DIR}/ci-templates/github/workflows"

# Copy fetch script verbatim; package-local.sh is rendered below with org substitutions
cp "${TEMPLATE_BASE}/scripts/fetch-upstream.sh" "${TARGET_DIR}/scripts/fetch-upstream.sh"
chmod +x "${TARGET_DIR}/scripts/fetch-upstream.sh"
cp "${TEMPLATE_BASE}/scripts/upstream-check.sh" "${TARGET_DIR}/scripts/upstream-check.sh"
chmod +x "${TARGET_DIR}/scripts/upstream-check.sh"
if [ -f "${TEMPLATE_BASE}/scripts/prepare-local-marketplace.py" ]; then
  cp "${TEMPLATE_BASE}/scripts/prepare-local-marketplace.py" \
     "${TARGET_DIR}/scripts/prepare-local-marketplace.py"
  chmod +x "${TARGET_DIR}/scripts/prepare-local-marketplace.py"
fi
for helper in \
  render-packaged-help.py \
  render-packaged-readme.py \
  prune-packaged-session-banner.py \
  baseline-upstream-check.py \
  select-latest-release.py \
  check-org-hook-collisions.py \
  archive-built-plugin.py \
  finalize-package-version.py \
  rewrite-packaged-origins.py \
  release.sh \
  reinit-org-repo.sh; do
  if [ -f "${TEMPLATE_BASE}/scripts/${helper}" ]; then
    helper_tmp="${TARGET_DIR}/scripts/.${helper}.new"
    cp "${TEMPLATE_BASE}/scripts/${helper}" "${helper_tmp}"
    chmod +x "${helper_tmp}"
    mv "${helper_tmp}" "${TARGET_DIR}/scripts/${helper}"
  fi
done

cp "${TEMPLATE_BASE}/ci-templates/github/workflows/package.yml" \
   "${TARGET_DIR}/ci-templates/github/workflows/package.yml"
cp "${TEMPLATE_BASE}/ci-templates/gitlab-ci.yml" \
   "${TARGET_DIR}/ci-templates/gitlab-ci.yml"
if [ -f "${TEMPLATE_BASE}/ci-requirements.lock" ]; then
  cp "${TEMPLATE_BASE}/ci-requirements.lock" "${TARGET_DIR}/ci-requirements.lock"
fi

cp "${TEMPLATE_BASE}/.gitignore" "${TARGET_DIR}/.gitignore"
if [ -f "${TEMPLATE_BASE}/org-skills/README.md" ]; then
  refresh_user_file \
    "${TEMPLATE_BASE}/org-skills/README.md" \
    "${TARGET_DIR}/org-skills/README.md" \
    "org-skills/README.md"
fi
# The rendered org-profile.yaml declares the org-block-risky-bash hook and
# package-policy.yaml allowlists it, so the script must ship with the scaffold.
refresh_user_file \
  "${TEMPLATE_BASE}/org-profile/hooks/guard.py" \
  "${TARGET_DIR}/org-profile/hooks/guard.py" \
  "org-profile/hooks/guard.py"
chmod +x "${TARGET_DIR}/org-profile/hooks/guard.py"

refresh_user_file \
  "${TEMPLATE_BASE}/org-profile/package-policy.yaml" \
  "${TARGET_DIR}/org-profile/package-policy.yaml" \
  "org-profile/package-policy.yaml"

if [ "${DEMO_CONTENT}" = true ]; then
  refresh_user_file \
    "${TEMPLATE_BASE}/org-profile/requirements-example.yaml" \
    "${TARGET_DIR}/org-profile/requirements.yaml" \
    "org-profile/requirements.yaml"
fi

# ── Render Makefile ───────────────────────────────────────────────────────────

E_PLUGIN=$(sed_escape "${PLUGIN_NAME}")
E_PACKAGE_VERSION=$(sed_escape "${PACKAGE_VERSION}")
E_UPSTREAM_REF=$(sed_escape "${UPSTREAM_REF}")
INTERNAL_REPOSITORY_ASSIGNMENT="INTERNAL_REPOSITORY_URL ?="
if [ -n "${INTERNAL_REPOSITORY_URL}" ]; then
  INTERNAL_REPOSITORY_ASSIGNMENT="${INTERNAL_REPOSITORY_ASSIGNMENT} ${INTERNAL_REPOSITORY_URL}"
fi
E_INTERNAL_REPOSITORY_ASSIGNMENT=$(sed_escape "${INTERNAL_REPOSITORY_ASSIGNMENT}")
sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/^APPSEC_ADVISOR_REF := .*$/APPSEC_ADVISOR_REF := ${E_UPSTREAM_REF}/" \
  -e "s/^PACKAGE_VERSION ?= 0.1.0$/PACKAGE_VERSION ?= ${E_PACKAGE_VERSION}/" \
  -e "s|^INTERNAL_REPOSITORY_URL ?=$|${E_INTERNAL_REPOSITORY_ASSIGNMENT}|" \
  "${TEMPLATE_BASE}/Makefile" > "${TARGET_DIR}/Makefile"

# ── Render org-profile.yaml ───────────────────────────────────────────────────

TODAY="$(date +%Y.%m.1)"
E_ORG_ID=$(sed_escape "${ORG_ID}")
E_ORG_NAME=$(sed_escape "${ORG_NAME}")
E_OWNER=$(sed_escape "${OWNER}")
E_ORG_NAME_YAML=$(sed_escape "$(printf '%s' "${ORG_NAME}" | yaml_quote)")
E_OWNER_YAML=$(sed_escape "$(printf '%s' "${OWNER}" | yaml_quote)")
E_LABEL_YAML=$(sed_escape "$(printf '%s' "${ORG_NAME} AppSec Requirements" | yaml_quote)")
E_BANNER_HEADLINE_YAML=$(sed_escape "$(printf '%s' "${OWNER_PREFIX} AppSec Advisor" | yaml_quote)")

PROFILE_PATH="${TARGET_DIR}/org-profile/org-profile.yaml"
if [ "${REINIT}" = true ] && [ -f "${PROFILE_PATH}" ] && \
   ! validate_utf8_file "${PROFILE_PATH}" quiet; then
  if [ "${REINIT_MODE}" = true ]; then
    validate_utf8_file "${PROFILE_PATH}"
  fi

  echo "WARNING: The existing organization profile contains invalid UTF-8." >&2
  echo "         It may have been created by an older initializer." >&2
  read -r -p "Back it up and generate a fresh profile from the values entered above? [y/N]: " _profile_repair_reply || _profile_repair_reply=""
  case "${_profile_repair_reply}" in
    [yY]*)
      PROFILE_BACKUP_DIR="${TARGET_DIR}/.reinit-backups"
      if [ -L "${PROFILE_BACKUP_DIR}" ] || \
         { [ -e "${PROFILE_BACKUP_DIR}" ] && [ ! -d "${PROFILE_BACKUP_DIR}" ]; }; then
        echo "ERROR: recovery backup path is not a regular directory: ${PROFILE_BACKUP_DIR}" >&2
        exit 2
      fi
      mkdir -p "${PROFILE_BACKUP_DIR}"
      chmod 700 "${PROFILE_BACKUP_DIR}"
      PROFILE_BACKUP="${PROFILE_BACKUP_DIR}/org-profile.yaml.invalid-utf8.bak"
      PROFILE_BACKUP_INDEX=1
      while [ -e "${PROFILE_BACKUP}" ]; do
        PROFILE_BACKUP="${PROFILE_BACKUP_DIR}/org-profile.yaml.invalid-utf8.bak.${PROFILE_BACKUP_INDEX}"
        PROFILE_BACKUP_INDEX=$((PROFILE_BACKUP_INDEX + 1))
      done
      mv -- "${PROFILE_PATH}" "${PROFILE_BACKUP}"
      echo "  backed up: ${PROFILE_BACKUP}"
      ;;
    *)
      validate_utf8_file "${PROFILE_PATH}"
      ;;
  esac
fi

PROFILE_CANDIDATE="${CANDIDATE_DIR}/org-profile.yaml"
if [ "${DEMO_CONTENT}" = true ]; then
  sed \
    -e "s/id: acme/id: ${E_ORG_ID}/" \
    -e "s/name: Acme Corp/name: ${E_ORG_NAME_YAML}/" \
    -e "s/profile_version: \"2026.06.1\"/profile_version: \"${TODAY}\"/" \
    -e "s/owner: Acme AppSec Team/owner: ${E_OWNER_YAML}/" \
    -e "s/headline: \"ACME AppSec Advisor\"/headline: ${E_BANNER_HEADLINE_YAML}/" \
    -e "s|requirements_yaml_url: \"https://security.example.internal/appsec-requirements.yaml\"|requirements_yaml_url: \"org-profile/requirements.yaml\"|" \
    -e "s|human_source_url: \"https://security.example.internal/appsec/requirements\"|human_source_url: \"# TODO: add URL to hosted requirements catalog\"|" \
    -e "s/label: \"Acme Corp AppSec Requirements\"/label: ${E_LABEL_YAML}/" \
    "${TEMPLATE_BASE}/org-profile/org-profile.yaml" > "${PROFILE_CANDIDATE}"
else
  sed \
    -e "s/id: acme/id: ${E_ORG_ID}/" \
    -e "s/name: Acme Corp/name: ${E_ORG_NAME_YAML}/" \
    -e "s/profile_version: \"2026.06.1\"/profile_version: \"${TODAY}\"/" \
    -e "s/owner: Acme AppSec Team/owner: ${E_OWNER_YAML}/" \
    -e "s/headline: \"ACME AppSec Advisor\"/headline: ${E_BANNER_HEADLINE_YAML}/" \
    -e "s|requirements_yaml_url: \"https://security.example.internal/appsec-requirements.yaml\"|requirements_yaml_url: \"# TODO: add URL to hosted requirements catalog\"|" \
    -e "/human_source_url:/d" \
    -e "/label: \"Acme Corp AppSec Requirements\"/d" \
    "${TEMPLATE_BASE}/org-profile/org-profile.yaml" > "${PROFILE_CANDIDATE}"
fi

if [ "${BASELINE_ENABLED}" = false ]; then
  PROFILE_EDITED="${CANDIDATE_DIR}/org-profile-baseline.yaml"
  sed '/^baseline:/,/^[^ ]/ s/^  enabled: true$/  enabled: false/' \
    "${PROFILE_CANDIDATE}" > "${PROFILE_EDITED}"
  mv "${PROFILE_EDITED}" "${PROFILE_CANDIDATE}"
fi
if [ "${STATUSLINE_ENABLED}" = false ]; then
  PROFILE_EDITED="${CANDIDATE_DIR}/org-profile-banner.yaml"
  sed '/^banner:/,/^[^ ]/ s/^  enabled: true$/  enabled: false/' \
    "${PROFILE_CANDIDATE}" > "${PROFILE_EDITED}"
  mv "${PROFILE_EDITED}" "${PROFILE_CANDIDATE}"
fi
refresh_user_file \
  "${PROFILE_CANDIDATE}" \
  "${TARGET_DIR}/org-profile/org-profile.yaml" \
  "org-profile/org-profile.yaml"

# Validate both newly rendered profiles and existing profiles retained during
# reinitialization before the upstream packager can produce a Python traceback.
validate_utf8_file "${TARGET_DIR}/org-profile/org-profile.yaml"
migrate_package_policy \
  "${TARGET_DIR}/org-profile/package-policy.yaml" \
  "${TARGET_DIR}/org-profile/org-profile.yaml"

# ── Render organization.md ────────────────────────────────────────────────────

ORGANIZATION_CANDIDATE="${CANDIDATE_DIR}/organization.md"
cat > "${ORGANIZATION_CANDIDATE}" <<EOF
# ${ORG_NAME} — Organization Context

Replace this stub with a short, factual description of your organization,
maintained by the AppSec or platform team. This file is loaded as reference data into
threat model analyses — it can inform findings, but it cannot change severity
rules, QA gates, schemas, permissions, or tool behavior.

Keep this under 50 KB. Plain Markdown only.
EOF
refresh_user_file \
  "${ORGANIZATION_CANDIDATE}" \
  "${TARGET_DIR}/org-profile/context/organization.md" \
  "org-profile/context/organization.md"

# ── Render actors stub ────────────────────────────────────────────────────────

ACTORS_CANDIDATE="${CANDIDATE_DIR}/custom-actors.yaml"
cat > "${ACTORS_CANDIDATE}" <<EOF
# Custom threat actors for ${ORG_NAME}.
# Add, edit, or delete entries as needed.
# Schema reference: https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md
actors: []
EOF
refresh_user_file \
  "${ACTORS_CANDIDATE}" \
  "${TARGET_DIR}/org-profile/actors/custom-actors.yaml" \
  "org-profile/actors/custom-actors.yaml"

# ── Render AGENTS.md ──────────────────────────────────────────────────────────

AGENTS_CANDIDATE="${CANDIDATE_DIR}/AGENTS.md"
sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  "${TEMPLATE_BASE}/AGENTS.md" > "${AGENTS_CANDIDATE}"
refresh_user_file \
  "${AGENTS_CANDIDATE}" \
  "${TARGET_DIR}/AGENTS.md" \
  "AGENTS.md"

# ── Render README.md ──────────────────────────────────────────────────────────

README_CANDIDATE="${CANDIDATE_DIR}/README.md"
if [ -n "${INTERNAL_REPOSITORY_URL}" ]; then
  INTERNAL_REPOSITORY_LINK="Internal packaging repository: [open repository](<${INTERNAL_REPOSITORY_URL}>)"
else
  INTERNAL_REPOSITORY_LINK=""
fi
E_INTERNAL_REPOSITORY_LINK=$(sed_escape "${INTERNAL_REPOSITORY_LINK}")
sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  -e "s/Acme AppSec Team/${E_OWNER}/g" \
  -e "s|<!-- INTERNAL_REPOSITORY_LINK -->|${E_INTERNAL_REPOSITORY_LINK}|" \
  "${TEMPLATE_BASE}/README.example.md" > "${README_CANDIDATE}"
refresh_user_file \
  "${README_CANDIDATE}" \
  "${TARGET_DIR}/README.md" \
  "README.md"

# ── Render maintainer runbook ─────────────────────────────────────────────────

RUNBOOK_CANDIDATE="${CANDIDATE_DIR}/MAINTAINER-RUNBOOK.md"
sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  -e "s/Acme AppSec Team/${E_OWNER}/g" \
  -e "s|<!-- INTERNAL_REPOSITORY_LINK -->|${E_INTERNAL_REPOSITORY_LINK}|" \
  "${TEMPLATE_BASE}/docs/MAINTAINER-RUNBOOK.example.md" > "${RUNBOOK_CANDIDATE}"
refresh_user_file \
  "${RUNBOOK_CANDIDATE}" \
  "${TARGET_DIR}/docs/MAINTAINER-RUNBOOK.md" \
  "docs/MAINTAINER-RUNBOOK.md"

# ── Render package-local.sh with correct org name ─────────────────────────────

sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  "${TEMPLATE_BASE}/scripts/package-local.sh" > "${TARGET_DIR}/scripts/package-local.sh"
chmod +x "${TARGET_DIR}/scripts/package-local.sh"

# ── Render CI files with correct plugin name ──────────────────────────────────

for CI_FILE in \
  "${TARGET_DIR}/ci-templates/github/workflows/package.yml" \
  "${TARGET_DIR}/ci-templates/gitlab-ci.yml"; do
  CI_EDITED="${CI_FILE}.new"
  sed \
    -e "s/acme-appsec/${E_PLUGIN}/g" \
    -e "s/Acme Corp/${E_ORG_NAME}/g" \
    -e "s/0\.1\.0/${E_PACKAGE_VERSION}/g" \
    "${CI_FILE}" > "${CI_EDITED}"
  mv "${CI_EDITED}" "${CI_FILE}"
done

# ── Init git repo ─────────────────────────────────────────────────────────────

cd "${TARGET_DIR}"
if [ ! -e .git ]; then
  git init -q
  git symbolic-ref HEAD refs/heads/main
fi
if [ -n "${INTERNAL_REPOSITORY_URL}" ]; then
  if EXISTING_ORIGIN=$(git remote get-url origin 2>/dev/null); then
    if [ "${EXISTING_ORIGIN}" != "${INTERNAL_REPOSITORY_URL}" ]; then
      echo "WARNING: existing origin differs from INTERNAL_REPOSITORY_URL; keeping ${EXISTING_ORIGIN}" >&2
    fi
  else
    git remote add origin "${INTERNAL_REPOSITORY_URL}"
  fi
fi
if [ "${REINIT}" = true ]; then
  echo "(reinitialization changes left uncommitted for review)"
else
  git add .
  if git diff --cached --quiet; then
    echo "(no changes to commit)"
  else
    if ! git commit -q -m "init: ${PLUGIN_NAME} packaging repo for ${ORG_NAME}"; then
      echo "ERROR: the repository was created and files were staged, but the initial Git commit failed." >&2
      echo "Review the Git error above, then commit the staged files manually." >&2
      exit 2
    fi
  fi
fi

BUILD_STATE=skipped
_build_answered=false
if [ "${REINIT_MODE}" = true ]; then
  _build_answered=true
  case "${APPSEC_REINIT_BUILD:-1}" in
    0|false|no|off) _build_reply=n ;;
    *) _build_reply=y ;;
  esac
elif read -r -p "Build the plugin now? [Y/n]: " _build_reply; then
  _build_answered=true
fi
if [ "${_build_answered}" = true ]; then
  case "${_build_reply}" in
    [nN]*) ;;
    *)
      echo ""
      echo "==> Building plugin …"
      if ! check_build_python_modules; then
        BUILD_STATE=failed
        echo "WARNING: The packaging repo is ready, but the initial plugin build was skipped." >&2
      elif make package; then
        BUILD_STATE=succeeded
      else
        BUILD_STATE=failed
        echo "" >&2
        echo "WARNING: The packaging repo is ready, but the initial plugin build failed." >&2
        echo "         Fix the reported build error, then run: make package" >&2
      fi
      ;;
  esac
fi

PACKAGING_ROOT="$(pwd)"

print_sharing_step() {
  local step="$1"
  echo "  ${step}. Share it with developers:"
  echo "     Release URL:"
  echo "       make release-package"
  echo "       Upload dist/${PLUGIN_NAME}-${PACKAGE_VERSION}.zip to an internal HTTPS location."
  echo "       Developers load it with:"
  echo "         claude --plugin-url \"<direct HTTPS URL to ${PLUGIN_NAME}-${PACKAGE_VERSION}.zip>\""
  echo "     Internal Marketplace:"
  echo "       Publish the plugin through your organization's Marketplace."
  echo "     See docs/MAINTAINER-RUNBOOK.md#releases-and-distribution for rollout options."
}

echo ""
echo "Done. Your packaging repo is ready at: ${PACKAGING_ROOT}"
if [ "${BUILD_STATE}" = succeeded ]; then
echo "The built plugin is ready at: ${PACKAGING_ROOT}/build/${PLUGIN_NAME}"
fi
echo ""
if [ "${REINIT_MODE}" = true ]; then
echo "Re-initialization complete. Selected template updates were applied and kept files preserved;"
echo "required package-policy entries were reconciled."
fi
echo "Next steps:"
if [ "${REINIT_MODE}" = true ]; then
  REINIT_STEP=1
  if [ "${BUILD_STATE}" = failed ]; then
    echo "  1. Retry the plugin build: make package"
    REINIT_STEP=2
  elif [ "${BUILD_STATE}" = skipped ]; then
    echo "  1. Build the plugin: make package"
    REINIT_STEP=2
  fi
  echo "  ${REINIT_STEP}. Load the plugin from any project you want to analyze:"
  echo "       claude --plugin-dir ${PACKAGING_ROOT}/build/${PLUGIN_NAME}"
  echo "  $((REINIT_STEP + 1)). Review and commit the reinitialization changes"
  print_sharing_step "$((REINIT_STEP + 2))"
  exit 0
fi
echo "  1. cd ${PACKAGING_ROOT}"
if [ "${BUILD_STATE}" = failed ]; then
echo "  2. Fix the reported build error, then build and test the plugin:"
echo "       make package"
elif [ "${BUILD_STATE}" = skipped ]; then
echo "  2. Build and test the plugin:"
echo "       make package"
else
echo "  2. Test the local build:"
fi
echo "       cd /path/to/your/project"
echo "       claude --plugin-dir ${PACKAGING_ROOT}/build/${PLUGIN_NAME}"
echo "  3. Customize it for your organization:"
echo "       - Replace org-profile/context/organization.md with your organization context."
echo "       - Add organization skills or enable, disable, and remove packaged skills."
echo "       - Adjust requirements, presets, banner, baseline, policy, and guardrails as needed."
echo "       - Rebuild after changes: make package"
echo "     See docs/MAINTAINER-RUNBOOK.md#organization-configuration"
print_sharing_step 4
