#!/usr/bin/env bash
# Validate the packaging repository, create an annotated release tag, and push
# only that tag. The selected CI pipeline rebuilds and publishes the package.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: releasing requires Bash; run it through: make release RELEASE_VERSION=x.y.z" >&2
  exit 2
fi
set -euo pipefail

RELEASE_VERSION="${1:-}"
RELEASE_BRANCH="main"
RELEASE_TAG="v${RELEASE_VERSION}"

if [ -z "${RELEASE_VERSION}" ]; then
  echo "ERROR: RELEASE_VERSION is required; use: make release RELEASE_VERSION=x.y.z" >&2
  exit 2
fi

for dependency in git make python3; do
  if ! command -v "${dependency}" >/dev/null 2>&1; then
    echo "ERROR: releasing requires ${dependency}" >&2
    exit 2
  fi
done

if ! PYTHONUTF8=1 python3 - "${RELEASE_VERSION}" <<'PY'
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
then
  echo "ERROR: RELEASE_VERSION must be valid SemVer, for example 1.2.0 or 1.2.0-internal.1" >&2
  exit 2
fi

if ! REPOSITORY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "ERROR: make release must run from a Git packaging repository" >&2
  exit 2
fi
cd "${REPOSITORY_ROOT}"

CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "${CURRENT_BRANCH}" != "${RELEASE_BRANCH}" ]; then
  echo "ERROR: releases must be created from ${RELEASE_BRANCH}; current branch is ${CURRENT_BRANCH:-<detached HEAD>}" >&2
  exit 2
fi

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo "ERROR: the working tree is not clean; commit or remove local changes before releasing" >&2
  exit 2
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  echo "ERROR: the packaging repository has no origin remote" >&2
  exit 2
fi

echo "==> Fetching origin/${RELEASE_BRANCH} and release tags"
if ! git fetch --quiet origin \
  "refs/heads/${RELEASE_BRANCH}:refs/remotes/origin/${RELEASE_BRANCH}" --tags; then
  echo "ERROR: could not fetch origin/${RELEASE_BRANCH} and release tags" >&2
  exit 2
fi

LOCAL_COMMIT="$(git rev-parse HEAD)"
REMOTE_COMMIT="$(git rev-parse "refs/remotes/origin/${RELEASE_BRANCH}")"
if [ "${LOCAL_COMMIT}" != "${REMOTE_COMMIT}" ]; then
  echo "ERROR: local ${RELEASE_BRANCH} must exactly match origin/${RELEASE_BRANCH} before releasing" >&2
  exit 2
fi

if git show-ref --verify --quiet "refs/tags/${RELEASE_TAG}"; then
  echo "ERROR: release tag ${RELEASE_TAG} already exists" >&2
  exit 2
fi

echo "==> Running release checks for ${RELEASE_VERSION}"
if make --no-print-directory PACKAGE_VERSION="${RELEASE_VERSION}" VERSION= release-check; then
  :
else
  RELEASE_CHECK_STATUS=$?
  echo "ERROR: release checks failed; no tag was created" >&2
  exit "${RELEASE_CHECK_STATUS}"
fi

if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo "ERROR: release checks changed the working tree; review those changes before releasing" >&2
  exit 2
fi

echo "==> Creating ${RELEASE_TAG}"
git tag -a "${RELEASE_TAG}" -m "Release ${RELEASE_VERSION}"

echo "==> Pushing ${RELEASE_TAG}; CI will build and publish the release"
if git push origin "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}"; then
  echo "Release tag pushed: ${RELEASE_TAG}"
else
  PUSH_STATUS=$?
  echo "ERROR: the tag push failed; local tag ${RELEASE_TAG} remains for inspection" >&2
  echo "After resolving the problem, push it with: git push origin refs/tags/${RELEASE_TAG}" >&2
  exit "${PUSH_STATUS}"
fi
