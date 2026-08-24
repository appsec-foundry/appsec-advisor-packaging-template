#!/usr/bin/env bash
# Creates a fresh org packaging repo for appsec-advisor.
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
# Or locally: scripts/init-org-repo.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

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


banner_enabled = False
inside_banner = False
for line in profile_lines:
    if line and not line[0].isspace():
        inside_banner = line.split(":", 1)[0] == "banner"
        continue
    if inside_banner and re.match(r"^  enabled:\s*true(?:\s+#.*)?$", line):
        banner_enabled = True

enabled = []
try:
    if ensure_available("skills", "help"):
        enabled.append("help")
    if banner_enabled and ensure_available("hooks", "session-banner"):
        enabled.append("session-banner")
except ValueError as error:
    print(f"ERROR: cannot migrate package policy: {error}", file=sys.stderr)
    raise SystemExit(2)

if enabled:
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
    print(f"  migrated: {policy_path} (enabled {', '.join(enabled)})")
PY
}

# ── Intro ─────────────────────────────────────────────────────────────────────

echo ""
echo "appsec-advisor — org packaging repo setup"
echo "────────────────────────────────────────────"
echo "This script creates a ready-to-use packaging repo for appsec-advisor."
echo "You will need: git, python3 (3.10+), make"
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
  OWNER="$(printf '%s' "${APPSEC_REINIT_OWNER:?}" | normalize_utf8)"
  DEMO_CONTENT="${APPSEC_REINIT_DEMO:?}"
  BASELINE_ENABLED="${APPSEC_REINIT_BASELINE:?}"
  OWNER_PREFIX="${ORG_ID^^}"
else
  ORG_NAME=$(ask "Organization name (e.g. Acme Corp)")
  ORG_ID=$(initials "${ORG_NAME}")
  ORG_ID=$(ask "Organization id (short lowercase abbreviation, e.g. 'acme', 'hl' — used in plugin name)" "${ORG_ID}")
  PLUGIN_NAME=$(ask "Plugin name (Claude Code command prefix)" "${ORG_ID}-appsec")
  PACKAGE_VERSION=$(ask_package_version)
  OWNER_PREFIX="${ORG_ID^^}"
  OWNER=$(ask "Team owner (e.g. AppSec Team)" "${OWNER_PREFIX} AppSec Team")
  TARGET_DIR=$(ask "Target directory" "./${ORG_ID}-appsec-advisor")

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
  trap 'rm -rf "${TMPDIR_CLONE}"' EXIT
  echo "==> Cloning template from GitHub …"
  git clone --depth 1 --branch "${TEMPLATE_REF}" \
    "https://github.com/appsec-foundry/appsec-advisor-packaging-template.git" \
    "${TMPDIR_CLONE}"
  TEMPLATE_BASE="${TMPDIR_CLONE}"
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
elif [ -e "${TARGET_DIR}" ]; then
  echo ""
  echo "Warning: '${TARGET_DIR}' already exists."
  echo "  Infrastructure files (Makefile, scripts/, ci-templates/, .gitignore)"
  echo "  will be updated. User-editable files (org-profile/, README.md, AGENTS.md)"
  echo "  will be kept if they already exist."
  echo "  Required package-policy entries may be reconciled."
  read -r -p "Re-initialize? [y/N]: " confirm
  case "${confirm}" in
    [yY]*) REINIT=true ;;
    *) echo "Aborted."; exit 1 ;;
  esac
  echo ""
fi

# Returns 0 (skip write) when re-initializing and the file already exists.
keep_if_reinit() { [ "${REINIT}" = true ] && [ -f "$1" ] && { echo "  kept: $1"; return 0; }; return 1; }

mkdir -p \
  "${TARGET_DIR}/org-profile/context" \
  "${TARGET_DIR}/org-profile/actors" \
  "${TARGET_DIR}/org-profile/hooks" \
  "${TARGET_DIR}/org-skills" \
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
  archive-built-plugin.py \
  finalize-package-version.py \
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

cp "${TEMPLATE_BASE}/.gitignore" "${TARGET_DIR}/.gitignore"
if [ -f "${TEMPLATE_BASE}/org-skills/README.md" ]; then
  keep_if_reinit "${TARGET_DIR}/org-skills/README.md" || \
    cp "${TEMPLATE_BASE}/org-skills/README.md" \
       "${TARGET_DIR}/org-skills/README.md"
fi
# The rendered org-profile.yaml declares the block-risky-bash hook and
# package-policy.yaml allowlists it, so the script must ship with the scaffold.
keep_if_reinit "${TARGET_DIR}/org-profile/hooks/guard.py" || {
  cp "${TEMPLATE_BASE}/org-profile/hooks/guard.py" \
     "${TARGET_DIR}/org-profile/hooks/guard.py"
  chmod +x "${TARGET_DIR}/org-profile/hooks/guard.py"
}

keep_if_reinit "${TARGET_DIR}/org-profile/package-policy.yaml" || \
  cp "${TEMPLATE_BASE}/org-profile/package-policy.yaml" \
     "${TARGET_DIR}/org-profile/package-policy.yaml"

if [ "${DEMO_CONTENT}" = true ]; then
  keep_if_reinit "${TARGET_DIR}/org-profile/requirements.yaml" || \
    cp "${TEMPLATE_BASE}/org-profile/requirements-example.yaml" \
       "${TARGET_DIR}/org-profile/requirements.yaml"
fi

# ── Render Makefile ───────────────────────────────────────────────────────────

E_PLUGIN=$(sed_escape "${PLUGIN_NAME}")
E_PACKAGE_VERSION=$(sed_escape "${PACKAGE_VERSION}")
sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/^PACKAGE_VERSION ?= 0.1.0$/PACKAGE_VERSION ?= ${E_PACKAGE_VERSION}/" \
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

if ! keep_if_reinit "${TARGET_DIR}/org-profile/org-profile.yaml"; then
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
      "${TEMPLATE_BASE}/org-profile/org-profile.yaml" > "${TARGET_DIR}/org-profile/org-profile.yaml"
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
      "${TEMPLATE_BASE}/org-profile/org-profile.yaml" > "${TARGET_DIR}/org-profile/org-profile.yaml"
  fi

  if [ "${BASELINE_ENABLED}" = false ]; then
    sed -i '/^compatibility:/i baseline:\n  enabled: false\n' \
      "${TARGET_DIR}/org-profile/org-profile.yaml"
  fi
fi

# Validate both newly rendered profiles and existing profiles retained during
# reinitialization before the upstream packager can produce a Python traceback.
validate_utf8_file "${TARGET_DIR}/org-profile/org-profile.yaml"
migrate_package_policy \
  "${TARGET_DIR}/org-profile/package-policy.yaml" \
  "${TARGET_DIR}/org-profile/org-profile.yaml"

# ── Render organization.md ────────────────────────────────────────────────────

keep_if_reinit "${TARGET_DIR}/org-profile/context/organization.md" || cat > "${TARGET_DIR}/org-profile/context/organization.md" <<EOF
# ${ORG_NAME} — Organization Context

Replace this stub with a short, factual description of your organization,
maintained by the AppSec or platform team. This file is loaded as reference data into
threat model analyses — it can inform findings, but it cannot change severity
rules, QA gates, schemas, permissions, or tool behavior.

Keep this under 50 KB. Plain Markdown only.
EOF

# ── Render actors stub ────────────────────────────────────────────────────────

keep_if_reinit "${TARGET_DIR}/org-profile/actors/custom-actors.yaml" || cat > "${TARGET_DIR}/org-profile/actors/custom-actors.yaml" <<EOF
# Custom threat actors for ${ORG_NAME}.
# Add, edit, or delete entries as needed.
# Schema reference: https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md
actors: []
EOF

# ── Render AGENTS.md ──────────────────────────────────────────────────────────

keep_if_reinit "${TARGET_DIR}/AGENTS.md" || sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  "${TEMPLATE_BASE}/AGENTS.md" > "${TARGET_DIR}/AGENTS.md"

# ── Render README.md ──────────────────────────────────────────────────────────

keep_if_reinit "${TARGET_DIR}/README.md" || sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  -e "s/Acme AppSec Team/${E_OWNER}/g" \
  "${TEMPLATE_BASE}/README.example.md" > "${TARGET_DIR}/README.md"

# ── Render package-local.sh with correct org name ─────────────────────────────

sed \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  "${TEMPLATE_BASE}/scripts/package-local.sh" > "${TARGET_DIR}/scripts/package-local.sh"
chmod +x "${TARGET_DIR}/scripts/package-local.sh"

# ── Render CI files with correct plugin name ──────────────────────────────────

sed -i \
  -e "s/acme-appsec/${E_PLUGIN}/g" \
  -e "s/Acme Corp/${E_ORG_NAME}/g" \
  -e "s/0\.1\.0/${E_PACKAGE_VERSION}/g" \
  "${TARGET_DIR}/ci-templates/github/workflows/package.yml" \
  "${TARGET_DIR}/ci-templates/gitlab-ci.yml"

# ── Init git repo ─────────────────────────────────────────────────────────────

cd "${TARGET_DIR}"
if [ ! -e .git ]; then
  git init -q -b main
fi
if [ "${REINIT}" = true ]; then
  echo "(reinitialization changes left uncommitted for review)"
else
  git add .
  if git diff --cached --quiet; then
    echo "(no changes to commit)"
  else
    git commit -q -m "init: ${PLUGIN_NAME} packaging repo for ${ORG_NAME}"
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
      if make package; then
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
echo ""
echo "Done. Your packaging repo is ready at: ${PACKAGING_ROOT}"
if [ "${BUILD_STATE}" = succeeded ]; then
echo "The built plugin is ready at: ${PACKAGING_ROOT}/build/${PLUGIN_NAME}"
fi
echo ""
if [ "${REINIT_MODE}" = true ]; then
echo "Re-initialization complete. Existing organization files and settings were preserved;"
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
  exit 0
fi
echo "  1. cd ${PACKAGING_ROOT}"
if [ "${DEMO_CONTENT}" = true ]; then
echo "  2. Edit org-profile/requirements.yaml — replace demo entries with your real requirements"
echo "     When ready to host it centrally, set requirements_yaml_url to an https:// URL in org-profile/org-profile.yaml"
else
echo "  2. Edit org-profile/org-profile.yaml — set requirements_yaml_url to your requirements catalog"
fi
echo "  3. Edit org-profile/context/organization.md — describe your org for analyses"
LOAD_STEP=4
if [ "${BUILD_STATE}" = failed ]; then
echo "  4. Retry the plugin build: make package"
LOAD_STEP=5
elif [ "${BUILD_STATE}" = skipped ]; then
echo "  4. Build the plugin: make package"
LOAD_STEP=5
else
echo "     The initial build is complete; run make package again only after changing configuration."
fi
echo "  ${LOAD_STEP}. Load the plugin from any project you want to analyze:"
echo "       cd /path/to/your/project"
echo "       claude --plugin-dir ${PACKAGING_ROOT}/build/${PLUGIN_NAME}"
echo ""
echo "Further steps (optional):"
echo "  - Customize the available skills:"
echo "       add organization skills or restrict bundled skills; see README.md#customize-skills"
echo "  - Distribute the tested plugin through an internal Claude Code Marketplace"
