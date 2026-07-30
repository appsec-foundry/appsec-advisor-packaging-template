#!/usr/bin/env bash
set -euo pipefail

SOURCE="${APPSEC_ADVISOR_SOURCE:-}"
DEST="${APPSEC_ADVISOR_DEST:-upstream/appsec-advisor}"
UPSTREAM_URL="${APPSEC_ADVISOR_URL:-https://github.com/matthiasrohr/appsec-advisor.git}"
INTERNAL_NAME="${INTERNAL_NAME:-acme-appsec}"
VERSION="${VERSION:-}"
ORG_ID="${ORG_ID:-${INTERNAL_NAME%%-*}}"
ORG_REV="${ORG_REV:-1}"
ARCHIVE="${ARCHIVE:-0}"
DESCRIPTION="${DESCRIPTION:-Internal packaged build of appsec-advisor with Acme Corp defaults.}"
ORG_SKILLS_DIR="${ORG_SKILLS_DIR:-org-skills}"
TEMP_SOURCE=""

cleanup() {
  if [ -n "${TEMP_SOURCE}" ]; then
    rm -rf "${TEMP_SOURCE}"
  fi
}
trap cleanup EXIT

validate_skill_name() {
  local skill_name="$1"
  if [[ ! "${skill_name}" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "ERROR: org skill name must start with a lowercase letter or digit and contain only lowercase letters, digits, '.', '_' and '-': ${skill_name}" >&2
    exit 2
  fi
}

overlay_org_skills() {
  local org_skills_dir="$1"
  local source_dir="$2"
  local found=0
  local skill_dir
  local skill_name

  if [ ! -d "${org_skills_dir}" ]; then
    return 0
  fi

  while IFS= read -r skill_dir; do
    skill_name="$(basename "${skill_dir}")"
    validate_skill_name "${skill_name}"

    if [ ! -f "${skill_dir}/SKILL.md" ]; then
      echo "ERROR: org skill ${org_skills_dir}/${skill_name} must contain SKILL.md" >&2
      exit 2
    fi
    if [ -e "${source_dir}/skills/${skill_name}" ]; then
      echo "ERROR: org skill '${skill_name}' would overwrite an upstream skill; choose a different name" >&2
      exit 2
    fi
    found=1
  done < <(find "${org_skills_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

  if [ "${found}" = 0 ]; then
    return 0
  fi

  TEMP_SOURCE="$(mktemp -d "${TMPDIR:-/tmp}/appsec-advisor-source.XXXXXX")"
  cp -a "${source_dir}/." "${TEMP_SOURCE}/"
  mkdir -p "${TEMP_SOURCE}/skills"

  while IFS= read -r skill_dir; do
    skill_name="$(basename "${skill_dir}")"
    cp -a "${skill_dir}" "${TEMP_SOURCE}/skills/${skill_name}"
  done < <(find "${org_skills_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

  SOURCE="${TEMP_SOURCE}"
}

# Derive the package version from the upstream checkout plus an org revision:
#   <upstream-version>+<org-id>.<org-rev>     e.g. 0.5.1-beta+acme.3
# The left half is SemVer build metadata's only job here: keep the lineage of a
# build visible, since package-surface.json records upstream_url but not the ref.
# Off a branch tip there is no tag to name, so fall back to ref + short sha.
# An explicit VERSION always wins (CI override, one-off builds).
semver_safe() {
  printf '%s' "$1" | tr -c '0-9A-Za-z-' '-'
}

derive_version() {
  local source="$1"
  local upstream sha
  upstream="$(git -C "${source}" describe --tags --exact-match 2>/dev/null || true)"
  upstream="${upstream#v}"
  if [ -z "${upstream}" ]; then
    sha="$(git -C "${source}" rev-parse --short HEAD 2>/dev/null || true)"
    upstream="0.0.0-$(semver_safe "${APPSEC_ADVISOR_REF:-unknown}")${sha:+.g${sha}}"
  fi
  printf '%s+%s.%s' "${upstream}" "$(semver_safe "${ORG_ID}")" "$(semver_safe "${ORG_REV}")"
}

# MCP servers are declared in org-profile.yaml under `mcp:` and written by the
# upstream packager. This repo used to copy an `org-mcp.json` over the finished
# build instead — which silently replaced whatever the profile produced,
# including the server selection from package-policy.yaml. Declare them in the
# profile; secrets belong in ${ENV_VAR}, never in the file.

if [ -z "${SOURCE}" ]; then
  scripts/fetch-upstream.sh
  SOURCE="${DEST}"
fi

if [ ! -f "${SOURCE}/scripts/package_internal_plugin.py" ]; then
  echo "ERROR: APPSEC_ADVISOR_SOURCE is not an appsec-advisor checkout: ${SOURCE}" >&2
  exit 2
fi

if [ -z "${VERSION}" ]; then
  VERSION="$(derive_version "${SOURCE}")"
  echo "==> Derived VERSION=${VERSION}"
fi

overlay_org_skills "${ORG_SKILLS_DIR}" "${SOURCE}"

EXTRA_ARGS=(--skip-archive)
if [ "${ARCHIVE}" = "1" ] || [ "${ARCHIVE}" = "true" ]; then
  EXTRA_ARGS=()
fi

python3 "${SOURCE}/scripts/package_internal_plugin.py" \
  --source "${SOURCE}" \
  --org-profile org-profile \
  --name "${INTERNAL_NAME}" \
  --version "${VERSION}" \
  --description "${DESCRIPTION}" \
  --upstream-url "${UPSTREAM_URL}" \
  --readme "build/${INTERNAL_NAME}/README.md" \
  "${EXTRA_ARGS[@]}"

python3 "${SOURCE}/scripts/smoke_test_package.py" \
  "build/${INTERNAL_NAME}" \
  --name "${INTERNAL_NAME}"
