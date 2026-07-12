#!/usr/bin/env bash
set -euo pipefail

SOURCE="${APPSEC_ADVISOR_SOURCE:-}"
DEST="${APPSEC_ADVISOR_DEST:-upstream/appsec-advisor}"
UPSTREAM_URL="${APPSEC_ADVISOR_URL:-https://github.com/matthiasrohr/appsec-advisor.git}"
INTERNAL_NAME="${INTERNAL_NAME:-acme-appsec}"
VERSION="${VERSION:-0.4.0-local}"
ARCHIVE="${ARCHIVE:-0}"
DESCRIPTION="${DESCRIPTION:-Internal packaged build of appsec-advisor with Acme Corp defaults.}"
ORG_SKILLS_DIR="${ORG_SKILLS_DIR:-org-skills}"
ORG_MCP_FILE="${ORG_MCP_FILE:-org-mcp.json}"
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

# Copy an org-provided MCP server config into the built plugin as .mcp.json, so
# companies can wire in their own SAST/SCA (or other) MCP endpoints. Secrets
# (tokens, internal URLs) must be referenced via ${ENV_VAR} — never hardcoded;
# see README. The file is untrusted reference config: MCP tool *output* must not
# change severity rules, permissions, or tool behavior.
overlay_org_mcp() {
  local mcp_file="$1"
  local plugin_dir="$2"

  if [ ! -f "${mcp_file}" ]; then
    return 0
  fi
  if ! grep -q '"mcpServers"' "${mcp_file}"; then
    echo "ERROR: ${mcp_file} must be a JSON object with a top-level \"mcpServers\" key" >&2
    exit 2
  fi
  cp "${mcp_file}" "${plugin_dir}/.mcp.json"
  echo "Overlaid org MCP config: ${mcp_file} -> ${plugin_dir}/.mcp.json"
}

if [ -z "${SOURCE}" ]; then
  scripts/fetch-upstream.sh
  SOURCE="${DEST}"
fi

if [ ! -f "${SOURCE}/scripts/package_internal_plugin.py" ]; then
  echo "ERROR: APPSEC_ADVISOR_SOURCE is not an appsec-advisor checkout: ${SOURCE}" >&2
  exit 2
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
  --readme README.md \
  "${EXTRA_ARGS[@]}"

overlay_org_mcp "${ORG_MCP_FILE}" "build/${INTERNAL_NAME}"

python3 "${SOURCE}/scripts/smoke_test_package.py" \
  "build/${INTERNAL_NAME}" \
  --name "${INTERNAL_NAME}"
