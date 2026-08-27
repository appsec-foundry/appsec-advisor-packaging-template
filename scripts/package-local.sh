#!/usr/bin/env bash
set -euo pipefail

SOURCE="${APPSEC_ADVISOR_SOURCE:-}"
DEST="${APPSEC_ADVISOR_DEST:-upstream/appsec-advisor}"
UPSTREAM_URL="${APPSEC_ADVISOR_URL:-https://github.com/appsec-foundry/appsec-advisor.git}"
INTERNAL_NAME="${INTERNAL_NAME:-acme-appsec}"
INTERNAL_REPOSITORY_URL="${INTERNAL_REPOSITORY_URL:-}"
PACKAGE_VERSION="${PACKAGE_VERSION:-0.1.0}"
VERSION="${VERSION:-}"
ARCHIVE="${ARCHIVE:-0}"
DESCRIPTION="${DESCRIPTION:-Internal packaged build of appsec-advisor with Acme Corp defaults.}"
ORG_SKILLS_DIR="${ORG_SKILLS_DIR:-org-skills}"
FETCHED=0
TEMP_SOURCE=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

validate_version() {
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
if match:
    prerelease = match.group(4)
    if prerelease and any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in prerelease.split(".")
    ):
        raise SystemExit(2)
    raise SystemExit(0)
raise SystemExit(2)
PY
}

read_core_version() {
  PYTHONUTF8=1 python3 - "$1/.claude-plugin/plugin.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
    version = data.get("version")
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    print(f"ERROR: cannot read upstream plugin version from {path}: {exc}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(version, str) or not version:
    print(f"ERROR: upstream plugin manifest has no version: {path}", file=sys.stderr)
    raise SystemExit(2)
print(version)
PY
}

# MCP servers are declared in org-profile.yaml under `mcp:` and written by the
# upstream packager. This repo used to copy an `org-mcp.json` over the finished
# build instead — which silently replaced whatever the profile produced,
# including the server selection from package-policy.yaml. Declare them in the
# profile; secrets belong in ${ENV_VAR}, never in the file.

if [ -z "${SOURCE}" ]; then
  scripts/fetch-upstream.sh
  SOURCE="${DEST}"
  FETCHED=1
fi

if [ ! -f "${SOURCE}/scripts/package_internal_plugin.py" ]; then
  echo "ERROR: APPSEC_ADVISOR_SOURCE is not an appsec-advisor checkout: ${SOURCE}" >&2
  exit 2
fi

if [ -z "${VERSION}" ]; then
  VERSION="${PACKAGE_VERSION}"
fi
if ! validate_version "${VERSION}"; then
  echo "ERROR: package version must be valid SemVer (for example 1.2.0 or 1.2.0-internal.1): ${VERSION}" >&2
  exit 2
fi
CORE_VERSION="$(read_core_version "${SOURCE}")"
if ! validate_version "${CORE_VERSION}"; then
  echo "ERROR: upstream plugin version is not valid SemVer: ${CORE_VERSION}" >&2
  exit 2
fi
# The upstream version string is shared by every commit between two version
# bumps, so a branch build such as `dev` is only identified by its revision.
# Read it before the org-skills overlay replaces SOURCE with a temporary copy.
CORE_COMMIT=""
CORE_REF=""
if [ -e "${SOURCE}/.git" ]; then
  CORE_COMMIT="$(git -C "${SOURCE}" rev-parse HEAD 2>/dev/null || true)"
  if [ "${FETCHED}" = 1 ] && [ -f "${DEST%/}.ref" ]; then
    CORE_REF="$(head -n 1 "${DEST%/}.ref")"
  else
    CORE_REF="$(git -C "${SOURCE}" describe --tags --exact-match HEAD 2>/dev/null || true)"
  fi
fi

echo "==> Package VERSION=${VERSION} (appsec-advisor core ${CORE_VERSION})"
if [ -n "${CORE_COMMIT}" ]; then
  echo "==> Upstream revision: ${CORE_REF:+${CORE_REF} @ }${CORE_COMMIT}"
fi

PYTHONDONTWRITEBYTECODE=1 python3 "${SCRIPT_DIR}/check-org-hook-collisions.py" \
  --source "${SOURCE}" \
  --profile org-profile/org-profile.yaml

overlay_org_skills "${ORG_SKILLS_DIR}" "${SOURCE}"

# Do not leave an older same-version release artifact behind if regeneration
# fails before the new archive is ready.
if [ "${ARCHIVE}" = "1" ] || [ "${ARCHIVE}" = "true" ]; then
  python3 "${SCRIPT_DIR}/archive-built-plugin.py" \
    --clean-only \
    --name "${INTERNAL_NAME}" \
    --version "${VERSION}" \
    --dist-dir dist
fi

python3 "${SOURCE}/scripts/package_internal_plugin.py" \
  --source "${SOURCE}" \
  --org-profile org-profile \
  --name "${INTERNAL_NAME}" \
  --version "${CORE_VERSION}" \
  --description "${DESCRIPTION}" \
  --upstream-url "${UPSTREAM_URL}" \
  --info-url "${INTERNAL_REPOSITORY_URL}" \
  --readme "build/${INTERNAL_NAME}/README.md" \
  --skip-archive

# v0.6.0-beta.1 still contains links to the former personal repository
# namespace. Rewrite only repositories with verified appsec-foundry targets and
# fail if any unknown personal GitHub origin would remain in the package.
python3 "${SCRIPT_DIR}/rewrite-packaged-origins.py" \
  --plugin-root "build/${INTERNAL_NAME}"

# Upstream currently uses plugin.json.version both as the user-facing package
# identity and for compatibility.core checks. Preserve its version separately,
# then make the organization-owned version authoritative for Claude Code,
# generated help, the session banner, Marketplace metadata and archives.
python3 "${SCRIPT_DIR}/finalize-package-version.py" \
  --plugin-root "build/${INTERNAL_NAME}" \
  --package-version "${VERSION}" \
  --core-version "${CORE_VERSION}" \
  --core-ref "${CORE_REF}" \
  --core-commit "${CORE_COMMIT}"

# Prove that runtime profile resolution still checks compatibility against the
# upstream core after the visible manifest version has changed.
python3 "build/${INTERNAL_NAME}/scripts/validate_org_profile.py" \
  "build/${INTERNAL_NAME}/org-profile/org-profile.yaml"

# The package-specific help is derived only after the upstream packager has
# written its authoritative package-surface.json. The upstream source tree is
# never modified.
python3 "${SCRIPT_DIR}/render-packaged-help.py" \
  --plugin-root "build/${INTERNAL_NAME}"

# Replace the generic upstream README with a package-specific welcome and quick
# start derived from the same final surface and runtime configuration as help.
python3 "${SCRIPT_DIR}/render-packaged-readme.py" \
  --plugin-root "build/${INTERNAL_NAME}"

# A package policy that removes the SessionStart hook should also remove its
# unreferenced implementation from the distributed artifact.
python3 "${SCRIPT_DIR}/prune-packaged-session-banner.py" \
  --plugin-root "build/${INTERNAL_NAME}"

python3 "${SOURCE}/scripts/smoke_test_package.py" \
  "build/${INTERNAL_NAME}" \
  --name "${INTERNAL_NAME}"

# Archive the same directory that passed the smoke test. Letting the upstream
# packager archive earlier would capture its generic help instead.
if [ "${ARCHIVE}" = "1" ] || [ "${ARCHIVE}" = "true" ]; then
  python3 "${SCRIPT_DIR}/archive-built-plugin.py" \
    --plugin-root "build/${INTERNAL_NAME}" \
    --dist-dir dist
fi
