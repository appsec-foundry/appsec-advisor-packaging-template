#!/usr/bin/env bash
# Read-only drift check for the packaging-template ref stored by the initializer.
set -euo pipefail

URL="${APPSEC_ADVISOR_TEMPLATE_URL:-https://github.com/appsec-foundry/appsec-advisor-packaging-template.git}"
REF="${APPSEC_ADVISOR_TEMPLATE_REF:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

valid_template_ref() {
  case "$1" in
    ""|[!A-Za-z0-9]*|*[!A-Za-z0-9._/-]*|*..*|*//*|*/|*.) return 1 ;;
    *) return 0 ;;
  esac
}

is_commit_ref() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

valid_template_url() {
  local authority
  case "$1" in
    https://*)
      authority="${1#https://}"
      authority="${authority%%/*}"
      case "${authority}" in ""|*@*) return 1 ;; esac
      ;;
    ssh://*)
      authority="${1#ssh://}"
      authority="${authority%%/*}"
      case "${authority}" in ""|*:*@*) return 1 ;; esac
      ;;
    [A-Za-z0-9._-]*@[A-Za-z0-9._-]*:*) ;;
    *) return 1 ;;
  esac
}

if ! command -v git >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: packaging-template-check requires git and Python 3." >&2
  exit 2
fi
if ! valid_template_ref "${REF}"; then
  echo "ERROR: APPSEC_ADVISOR_TEMPLATE_REF is not a safe branch, tag, or commit: ${REF}" >&2
  exit 2
fi
if ! valid_template_url "${URL}"; then
  echo "ERROR: APPSEC_ADVISOR_TEMPLATE_URL must use HTTPS without credentials or an SSH Git URL." >&2
  exit 2
fi

if is_commit_ref "${REF}"; then
  if ! REMOTE_HEAD_LINE="$(git ls-remote -- "${URL}" HEAD)"; then
    echo "ERROR: could not query the packaging template at ${URL}." >&2
    exit 2
  fi
  REMOTE_HEAD="${REMOTE_HEAD_LINE%%[[:space:]]*}"
  if ! is_commit_ref "${REMOTE_HEAD}"; then
    echo "ERROR: could not resolve the packaging-template default branch at ${URL}." >&2
    exit 2
  fi
  echo "configured template commit: ${REF}"
  echo "current default-branch HEAD: ${REMOTE_HEAD}"
  if [ "${REF}" = "${REMOTE_HEAD}" ]; then
    echo "OK: packaging template is current"
    exit 0
  fi
  echo "UPDATE: packaging template has moved. Review commit ${REMOTE_HEAD}, then apply exactly that revision with:"
  echo "  make reinit APPSEC_ADVISOR_TEMPLATE_REF=${REMOTE_HEAD}"
  exit 1
fi

if ! TAG_MATCH="$(git ls-remote --tags --refs -- "${URL}" "refs/tags/${REF}")" ||
   ! BRANCH_MATCH="$(git ls-remote --heads -- "${URL}" "refs/heads/${REF}")"; then
  echo "ERROR: could not query packaging-template refs at ${URL}." >&2
  exit 2
fi
if [ -n "${BRANCH_MATCH}" ]; then
  BRANCH_HEAD="${BRANCH_MATCH%%[[:space:]]*}"
  if ! is_commit_ref "${BRANCH_HEAD}"; then
    echo "ERROR: could not resolve packaging-template branch '${REF}' at ${URL}." >&2
    exit 2
  fi
  echo "DRIFT: APPSEC_ADVISOR_TEMPLATE_REF=${REF} is a moving branch, not an exact template pin." >&2
  echo "Review commit ${BRANCH_HEAD}, then run: make reinit APPSEC_ADVISOR_TEMPLATE_REF=${BRANCH_HEAD}" >&2
  exit 1
fi
if [ -z "${TAG_MATCH}" ]; then
  echo "ERROR: packaging-template ref '${REF}' was not found at ${URL}." >&2
  exit 2
fi

if ! LATEST_TAG="$(git ls-remote --tags --refs -- "${URL}" 'v[0-9]*' |
  PYTHONUTF8=1 python3 "${SCRIPT_DIR}/select-latest-release.py")"; then
  echo "ERROR: could not determine packaging-template releases at ${URL}." >&2
  exit 2
fi
echo "configured template release: ${REF}"
if [ -z "${LATEST_TAG}" ] || [ "${REF}" = "${LATEST_TAG}" ]; then
  echo "OK: no newer packaging-template release was found"
  exit 0
fi
echo "UPDATE: newer packaging-template release available: ${LATEST_TAG}"
echo "Apply it with: make reinit APPSEC_ADVISOR_TEMPLATE_REF=${LATEST_TAG}"
exit 1
