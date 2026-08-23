#!/usr/bin/env bash
set -euo pipefail

# Read-only drift check against upstream appsec-advisor.
#
# Reports two independent kinds of drift WITHOUT touching upstream/ or build/:
#   - commit drift : the ref you build from now points at a different commit
#                    (new file state — e.g. a moving branch/trunk, or a
#                    re-pointed tag), or there is no local checkout yet.
#   - release drift: a newer v* release tag exists than the pinned ref.
#
# Exit codes:  0 = up to date   1 = drift detected   2 = error.

URL="${APPSEC_ADVISOR_URL:-https://github.com/appsec-foundry/appsec-advisor.git}"
REF="${APPSEC_ADVISOR_REF:-latest}"
DEST="${APPSEC_ADVISOR_DEST:-upstream/appsec-advisor}"

_latest_tag() {
  git ls-remote --tags --refs "${URL}" 'v[0-9]*' |
    awk -F/ '{print $NF}' |
    sort -V |
    tail -n 1
}

_remote_sha() { # _remote_sha <ref> -> commit sha (peels annotated tags)
  # ls-remote appends a `<sha> refs/tags/<t>^{}` line for annotated tags; the
  # last line is the commit the local checkout resolves to. NR==1 would be the
  # tag-object sha and produce false commit drift.
  git ls-remote "${URL}" "$1" | awk 'END {print $1}'
}

LATEST_TAG="$(_latest_tag)"

# Resolve the configured ref to whatever we would actually build from.
if [ "${REF}" = "latest" ]; then
  if [ -z "${LATEST_TAG}" ]; then
    echo "ERROR: no release tags found in ${URL}" >&2
    exit 2
  fi
  RESOLVED="${LATEST_TAG}"
else
  RESOLVED="${REF}"
fi

REMOTE_SHA="$(_remote_sha "${RESOLVED}")"
if [ -z "${REMOTE_SHA}" ]; then
  echo "ERROR: ref '${RESOLVED}' not found in ${URL}" >&2
  exit 2
fi

# Local checkout state — read-only, may be absent.
if [ -e "${DEST}" ] && git -C "${DEST}" rev-parse --git-dir >/dev/null 2>&1; then
  LOCAL_SHA="$(git -C "${DEST}" rev-parse HEAD)"
else
  LOCAL_SHA=""
fi

echo "upstream:       ${URL}"
echo "configured ref: ${REF} -> ${RESOLVED}"
echo "remote commit:  ${REMOTE_SHA}"
echo "local checkout: ${LOCAL_SHA:-<none>}"
echo "latest release: ${LATEST_TAG:-<none>}"

drift=0

# Commit drift: the resolved ref moved since the local checkout was built.
# With no local checkout (e.g. a stateless CI runner) commit drift cannot be
# assessed — that is not drift, so only release drift drives the exit code.
if [ -z "${LOCAL_SHA}" ]; then
  echo "NOTE: no local checkout at ${DEST} — commit drift not assessed (run 'make package')"
elif [ "${LOCAL_SHA}" != "${REMOTE_SHA}" ]; then
  echo "DRIFT (commit): ${RESOLVED} moved to ${REMOTE_SHA} (local is ${LOCAL_SHA})"
  drift=1
fi

# Release drift: a newer release tag exists than the pinned ref.
if [ "${REF}" != "latest" ] && [ -n "${LATEST_TAG}" ] && [ "${RESOLVED}" != "${LATEST_TAG}" ]; then
  newest="$(printf '%s\n%s\n' "${RESOLVED}" "${LATEST_TAG}" | sort -V | tail -n 1)"
  if [ "${newest}" = "${LATEST_TAG}" ]; then
    echo "DRIFT (release): newer release ${LATEST_TAG} available (pinned ref is ${REF})"
    drift=1
  fi
fi

if [ "${drift}" -eq 0 ]; then
  echo "OK: up to date with ${RESOLVED}"
fi
exit "${drift}"
