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
  PYTHONUTF8=1 python3 - "$1" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
try:
    path.read_bytes().decode("utf-8")
except UnicodeDecodeError as error:
    print(
        f"ERROR: {path} is not valid UTF-8 at byte {error.start}. "
        "Repair or replace this user-owned file before building.",
        file=sys.stderr,
    )
    raise SystemExit(2)
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
  OWNER="$(printf '%s' "${APPSEC_REINIT_OWNER:?}" | normalize_utf8)"
  DEMO_CONTENT="${APPSEC_REINIT_DEMO:?}"
  BASELINE_ENABLED="${APPSEC_REINIT_BASELINE:?}"
  OWNER_PREFIX="${ORG_ID^^}"
else
  ORG_NAME=$(ask "Organization name (e.g. Acme Corp)")
  ORG_ID=$(initials "${ORG_NAME}")
  ORG_ID=$(ask "Organization id (short lowercase abbreviation, e.g. 'acme', 'hl' — used in plugin name)" "${ORG_ID}")
  PLUGIN_NAME=$(ask "Plugin name (Claude Code command prefix)" "${ORG_ID}-appsec")
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
for helper in render-packaged-help.py archive-built-plugin.py reinit-org-repo.sh; do
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
sed "s/acme-appsec/${E_PLUGIN}/g" \
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

# Reinitialization deliberately keeps the user-owned profile. Validate it here
# so a file damaged by an older initializer fails with an actionable message
# before the upstream packager produces a Python traceback.
validate_utf8_file "${TARGET_DIR}/org-profile/org-profile.yaml"

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
echo "Re-initialization complete. Existing organization files and settings were preserved."
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
echo "  $((LOAD_STEP + 1)). Set up CI: make ci-github  or  make ci-gitlab"
