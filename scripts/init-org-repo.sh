#!/usr/bin/env bash
# Creates a fresh org packaging repo for appsec-advisor.
# Usage: bash <(curl -fsSL https://raw.githubusercontent.com/matthiasrohr/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
# Or locally: scripts/init-org-repo.sh
set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

ask() {
  local prompt="$1" default="${2:-}"
  local reply
  if [ -n "${default}" ]; then
    read -r -p "${prompt} [${default}]: " reply
    echo "${reply:-${default}}"
  else
    while true; do
      read -r -p "${prompt}: " reply
      [ -n "${reply}" ] && break
      echo "  (required)" >&2
    done
    echo "${reply}"
  fi
}

initials() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -s '+&/., -' ' ' | sed 's/^ //;s/ $//' | awk '{for(i=1;i<=NF;i++) printf substr($i,1,1)}'
}

# Escape a string for safe use as a sed replacement (escapes & \ and /).
sed_escape() {
  printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

# ── Intro ─────────────────────────────────────────────────────────────────────

echo ""
echo "appsec-advisor — org packaging repo setup"
echo "────────────────────────────────────────────"
echo "This script creates a ready-to-use packaging repo for appsec-advisor."
echo "You will need: git, python3 (3.10+), make"
echo ""

# ── Gather input ─────────────────────────────────────────────────────────────

ORG_NAME=$(ask "Organization name (e.g. Acme Corp)")
ORG_ID=$(initials "${ORG_NAME}")
ORG_ID=$(ask "Organization id (short lowercase abbreviation, e.g. 'acme', 'hl' — used in plugin name)" "${ORG_ID}")
PLUGIN_NAME=$(ask "Plugin name (Claude Code command prefix)" "${ORG_ID}-appsec")
OWNER_PREFIX=$(echo "${ORG_NAME}" | awk '{print $1}')
OWNER=$(ask "Team owner (e.g. AppSec Team)" "${OWNER_PREFIX} AppSec Team")
TARGET_DIR=$(ask "Target directory" "./${ORG_ID}-appsec-advisor")

read -r -p "Include demo content (example requirements + filled org profile)? [y/N]: " _demo_reply
case "${_demo_reply}" in
  [yY]*) DEMO_CONTENT=true ;;
  *)     DEMO_CONTENT=false ;;
esac

echo ""

# ── Source files ──────────────────────────────────────────────────────────────

# Resolve absolute path so relative-path invocations work correctly.
SCRIPT_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")" || true
TEMPLATE_BASE="${SCRIPT_ABS%/scripts/init-org-repo.sh}"

# When invoked via curl/pipe the path above resolves to something like /dev/fd/N
# which has no Makefile — fall back to cloning.
if [ ! -f "${TEMPLATE_BASE}/Makefile" ]; then
  TMPDIR_CLONE="$(mktemp -d)"
  trap 'rm -rf "${TMPDIR_CLONE}"' EXIT
  echo "==> Cloning template from GitHub …"
  git clone --depth 1 \
    "https://github.com/matthiasrohr/appsec-advisor-packaging-template.git" \
    "${TMPDIR_CLONE}"
  TEMPLATE_BASE="${TMPDIR_CLONE}"
fi

# ── Create repo ───────────────────────────────────────────────────────────────

REINIT=false
if [ -e "${TARGET_DIR}" ]; then
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
  "${TARGET_DIR}/org-skills" \
  "${TARGET_DIR}/scripts" \
  "${TARGET_DIR}/ci-templates/github/workflows"

# Copy fetch script verbatim; package-local.sh is rendered below with org substitutions
cp "${TEMPLATE_BASE}/scripts/fetch-upstream.sh" "${TARGET_DIR}/scripts/fetch-upstream.sh"
chmod +x "${TARGET_DIR}/scripts/fetch-upstream.sh"

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
E_LABEL=$(sed_escape "${ORG_NAME} AppSec Requirements")

if ! keep_if_reinit "${TARGET_DIR}/org-profile/org-profile.yaml"; then
  if [ "${DEMO_CONTENT}" = true ]; then
    sed \
      -e "s/id: acme/id: ${E_ORG_ID}/" \
      -e "s/name: Acme Corp/name: ${E_ORG_NAME}/" \
      -e "s/profile_version: \"2026.06.1\"/profile_version: \"${TODAY}\"/" \
      -e "s/owner: Acme AppSec Team/owner: ${E_OWNER}/" \
      -e "s|requirements_yaml_url: \"https://security.example.internal/appsec-requirements.yaml\"|requirements_yaml_url: \"org-profile/requirements.yaml\"|" \
      -e "s|human_source_url: \"https://security.example.internal/appsec/requirements\"|human_source_url: \"# TODO: add URL to hosted requirements catalog\"|" \
      -e "s/label: \"Acme Corp AppSec Requirements\"/label: \"${E_LABEL}\"/" \
      "${TEMPLATE_BASE}/org-profile/org-profile.yaml" > "${TARGET_DIR}/org-profile/org-profile.yaml"
  else
    sed \
      -e "s/id: acme/id: ${E_ORG_ID}/" \
      -e "s/name: Acme Corp/name: ${E_ORG_NAME}/" \
      -e "s/profile_version: \"2026.06.1\"/profile_version: \"${TODAY}\"/" \
      -e "s/owner: Acme AppSec Team/owner: ${E_OWNER}/" \
      -e "s|requirements_yaml_url: \"https://security.example.internal/appsec-requirements.yaml\"|requirements_yaml_url: \"# TODO: add URL to hosted requirements catalog\"|" \
      -e "/human_source_url:/d" \
      -e "/label: \"Acme Corp AppSec Requirements\"/d" \
      "${TEMPLATE_BASE}/org-profile/org-profile.yaml" > "${TARGET_DIR}/org-profile/org-profile.yaml"
  fi
fi

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
# Schema reference: https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/org-profiles.md
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
if [ "${REINIT}" = false ]; then
  git init -q
fi
git add .
if git diff --cached --quiet; then
  echo "(no changes to commit)"
else
  if [ "${REINIT}" = true ]; then
    git commit -q -m "reinit: update infrastructure files for ${PLUGIN_NAME}"
  else
    git commit -q -m "init: ${PLUGIN_NAME} packaging repo for ${ORG_NAME}"
  fi
fi

echo ""
echo "Done. Your packaging repo is ready at: ${TARGET_DIR}"
echo ""
echo "Next steps:"
echo "  1. cd ${TARGET_DIR}"
if [ "${DEMO_CONTENT}" = true ]; then
echo "  2. Edit org-profile/requirements.yaml — replace demo entries with your real requirements"
echo "     When ready to host it centrally, set requirements_yaml_url to an https:// URL in org-profile/org-profile.yaml"
else
echo "  2. Edit org-profile/org-profile.yaml — set requirements_yaml_url to your requirements catalog"
fi
echo "  3. Edit org-profile/context/organization.md — describe your org for analyses"
echo "  4. Run: make package"
echo "  5. Load the plugin from any project you want to analyze:"
echo "       cd /path/to/your/project"
echo "       claude --plugin-dir $(pwd)/build/${PLUGIN_NAME}"
echo "  6. Set up CI: make ci-github  or  make ci-gitlab"
