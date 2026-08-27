#!/usr/bin/env bash
set -euo pipefail

URL="${APPSEC_ADVISOR_URL:-https://github.com/appsec-foundry/appsec-advisor.git}"
REF="${APPSEC_ADVISOR_REF:-latest}"
DEST="${APPSEC_ADVISOR_DEST:-upstream/appsec-advisor}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout is detached, so the ref name it came from is not recoverable
# from it afterwards. Keep it beside the checkout, not inside it, so the
# packager never copies it into the built plugin.
REF_STATE="${DEST%/}.ref"

_record_ref() {
  printf '%s\n' "$1" >"${REF_STATE}"
}

case "${URL}" in
  *"github.com/appsec-foundry?tab=repositories"*)
    echo "ERROR: APPSEC_ADVISOR_URL must be the repository clone URL, not the GitHub repositories overview." >&2
    echo "Use: https://github.com/appsec-foundry/appsec-advisor.git" >&2
    exit 2
    ;;
esac

if [ -e "${DEST}" ]; then
  if ! git -C "${DEST}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: ${DEST} exists but is not a git checkout" >&2
    exit 2
  fi
else
  mkdir -p "$(dirname "${DEST}")"
  git clone --filter=blob:none --no-checkout "${URL}" "${DEST}"
fi

if git -C "${DEST}" remote get-url origin >/dev/null 2>&1; then
  git -C "${DEST}" remote set-url origin "${URL}"
else
  git -C "${DEST}" remote add origin "${URL}"
fi

_ask_yn() {
  # Non-interactive (no TTY, e.g. CI) always declines — builds must pin a ref.
  # Interactively, the fallback (use latest / use trunk) is the only path forward
  # when the requested ref is missing, so default to yes on an empty answer.
  [ -t 0 ] || return 1
  read -r -p "$1 [Y/n] " _answer || return 1
  case "${_answer}" in [nN]*) return 1 ;; *) return 0 ;; esac
}

_use_trunk() {
  echo "==> Fetching trunk (default branch) from ${URL}"
  git -C "${DEST}" fetch --depth 1 origin HEAD
  git -C "${DEST}" checkout --detach FETCH_HEAD
  _record_ref "HEAD"
  echo "==> Upstream ready at ${DEST} (trunk): $(git -C "${DEST}" rev-parse --short HEAD)"
  exit 0
}

_latest_tag() {
  git -C "${DEST}" ls-remote --tags --refs origin 'v[0-9]*' |
    PYTHONUTF8=1 python3 "${SCRIPT_DIR}/select-latest-release.py"
}

if [ "${REF}" = "latest" ]; then
  RESOLVED_REF="$(_latest_tag)"
  if [ -z "${RESOLVED_REF}" ]; then
    echo "WARN: no release tags found in ${URL}" >&2
    if _ask_yn "No release tags found. Use trunk (default branch) instead?"; then
      _use_trunk
    fi
    echo "ERROR: no release tags found and trunk was declined" >&2
    exit 2
  fi
  echo "==> Resolved APPSEC_ADVISOR_REF=latest to ${RESOLVED_REF}"
else
  TAG_EXISTS="$(git -C "${DEST}" ls-remote --tags --refs origin "refs/tags/${REF}")"
  BRANCH_EXISTS="$(git -C "${DEST}" ls-remote --heads origin "refs/heads/${REF}")"
  if [ -z "${TAG_EXISTS}" ] && [ -z "${BRANCH_EXISTS}" ]; then
    echo "WARN: ref '${REF}' not found in ${URL}" >&2
    LATEST_TAG="$(_latest_tag)"
    if [ -n "${LATEST_TAG}" ]; then
      if _ask_yn "Latest available release is '${LATEST_TAG}'. Use that instead?"; then
        RESOLVED_REF="${LATEST_TAG}"
        echo "==> Using latest release ${RESOLVED_REF}"
      elif _ask_yn "Use trunk (default branch) instead?"; then
        _use_trunk
      else
        echo "ERROR: ref '${REF}' not found and no alternative was chosen" >&2
        exit 2
      fi
    else
      if _ask_yn "No release tags found either. Use trunk (default branch) instead?"; then
        _use_trunk
      else
        echo "ERROR: ref '${REF}' not found and no release tags exist" >&2
        exit 2
      fi
    fi
  else
    RESOLVED_REF="${REF}"
  fi
fi

if git -C "${DEST}" ls-remote --exit-code --tags origin "refs/tags/${RESOLVED_REF}" >/dev/null 2>&1; then
  git -C "${DEST}" fetch --depth 1 origin "refs/tags/${RESOLVED_REF}:refs/tags/${RESOLVED_REF}"
  git -C "${DEST}" checkout --detach "refs/tags/${RESOLVED_REF}"
elif git -C "${DEST}" ls-remote --exit-code --heads origin "refs/heads/${RESOLVED_REF}" >/dev/null 2>&1; then
  git -C "${DEST}" fetch --depth 1 origin "refs/heads/${RESOLVED_REF}"
  git -C "${DEST}" checkout --detach FETCH_HEAD
else
  git -C "${DEST}" fetch --depth 1 origin "${RESOLVED_REF}"
  git -C "${DEST}" checkout --detach FETCH_HEAD
fi

_record_ref "${RESOLVED_REF}"
echo "==> Upstream ready at ${DEST}: $(git -C "${DEST}" rev-parse --short HEAD)"
