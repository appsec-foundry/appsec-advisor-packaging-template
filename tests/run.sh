#!/usr/bin/env bash
# Test driver + coverage gate for the packaging-template shell scripts.
#
# Each scenario exercises one script with stubbed `git`/`python3` (tests/stubs)
# so everything runs offline and deterministically. The scripts run under
# `set -x` with a marker PS4; executed line numbers are collected into a trace
# file and scored by tests/lib/coverage.py. The run fails if total line
# coverage drops below THRESHOLD (default 90) or any functional check fails.
#
# Pure bash spawning bash — no nested pipe orchestration to deadlock on.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
STUBS="$HERE/stubs"
REAL_GIT=/usr/bin/git
THRESHOLD="${THRESHOLD:-90}"

chmod +x "$STUBS"/* 2>/dev/null || true
export PATH="$STUBS:$PATH"
export PS4='@@COV:${BASH_SOURCE}:${LINENO}@@ '

FETCH="$ROOT/scripts/fetch-upstream.sh"
PKG="$ROOT/scripts/package-local.sh"
INIT="$ROOT/scripts/init-org-repo.sh"
CHECK="$ROOT/scripts/upstream-check.sh"

COV="$(mktemp)"
WORKROOT="$(mktemp -d)"
PASS=0
FAIL=0
trap 'rm -rf "$WORKROOT" "$COV"' EXIT

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_rc() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "rc=$3 want $2"; fi; }
newdir() { mktemp -d "$WORKROOT/d.XXXXXX"; }
mkfake() { # a minimal appsec-advisor checkout
  mkdir -p "$1/scripts" "$1/skills"
  local f
  for f in package_internal_plugin smoke_test_package validate_org_profile; do
    printf '# stub\n' >"$1/scripts/$f.py"
  done
}

# ── fetch-upstream.sh ────────────────────────────────────────────────────────
# fetch_run <name> <expect-rc> <predest 0|1> [VAR=val ...]
fetch_run() {
  local name="$1" exp="$2" predest="$3"
  shift 3
  local d
  d="$(newdir)"
  [ "$predest" = 1 ] && mkdir -p "$d/dest"
  (cd "$d" && env "$@" APPSEC_ADVISOR_DEST="$d/dest" timeout 15 bash -x "$FETCH") \
    </dev/null >/dev/null 2>>"$COV"
  assert_rc "$name" "$exp" "$?"
}
# fetch_tty <name> <expect-rc> <predest> <answers> [VAR=val ...]
fetch_tty() {
  local name="$1" exp="$2" predest="$3" answers="$4"
  shift 4
  local d ts rc
  d="$(newdir)"
  ts="$(mktemp "$WORKROOT/ts.XXXXXX")"
  [ "$predest" = 1 ] && mkdir -p "$d/dest"
  (cd "$d" && env "$@" APPSEC_ADVISOR_DEST="$d/dest" \
    timeout 15 script -qec "bash -x '$FETCH'" "$ts" <<<"$answers") >/dev/null 2>&1
  rc=$?
  cat "$ts" >>"$COV"
  assert_rc "$name" "$exp" "$rc"
}

echo "--- fetch-upstream.sh ---"
fetch_run "fetch: bad url overview" 2 0 \
  APPSEC_ADVISOR_URL="https://github.com/matthiasrohr?tab=repositories"
fetch_run "fetch: dest not a checkout" 2 1 GITSTUB_IS_CHECKOUT=0
fetch_run "fetch: latest->tag, clone, set-url" 0 0 \
  APPSEC_ADVISOR_REF=latest GITSTUB_TAGS="v0.3.0 v0.4.0" GITSTUB_HAS_ORIGIN=1
fetch_run "fetch: latest->tag, existing checkout, remote add" 0 1 \
  APPSEC_ADVISOR_REF=latest GITSTUB_TAGS="v0.4.0" GITSTUB_HAS_ORIGIN=0 GITSTUB_IS_CHECKOUT=1
fetch_run "fetch: explicit tag exists" 0 0 \
  APPSEC_ADVISOR_REF=v0.4.0 GITSTUB_TAGS="v0.4.0" GITSTUB_HAS_ORIGIN=1
fetch_run "fetch: explicit branch exists" 0 0 \
  APPSEC_ADVISOR_REF=main GITSTUB_HEADS="main" GITSTUB_HAS_ORIGIN=1
fetch_run "fetch: latest no tags noninteractive" 2 0 APPSEC_ADVISOR_REF=latest
fetch_tty "fetch: latest no tags -> trunk" 0 0 $'y' \
  APPSEC_ADVISOR_REF=latest GITSTUB_HAS_ORIGIN=1
fetch_tty "fetch: missing ref -> use latest" 0 0 $'y' \
  APPSEC_ADVISOR_REF=v9.9.9 GITSTUB_TAGS="v0.4.0" GITSTUB_HAS_ORIGIN=1
fetch_tty "fetch: missing ref -> decline latest -> trunk" 0 0 $'n\ny' \
  APPSEC_ADVISOR_REF=v9.9.9 GITSTUB_TAGS="v0.4.0" GITSTUB_HAS_ORIGIN=1
fetch_tty "fetch: missing ref -> decline both" 2 0 $'n\nn' \
  APPSEC_ADVISOR_REF=v9.9.9 GITSTUB_TAGS="v0.4.0" GITSTUB_HAS_ORIGIN=1
fetch_tty "fetch: missing ref no tags -> trunk" 0 0 $'y' \
  APPSEC_ADVISOR_REF=v9.9.9 GITSTUB_HAS_ORIGIN=1
fetch_run "fetch: missing ref no tags noninteractive" 2 0 \
  APPSEC_ADVISOR_REF=v9.9.9 GITSTUB_HAS_ORIGIN=1

# ── package-local.sh ─────────────────────────────────────────────────────────
echo "--- package-local.sh ---"
# SOURCE empty -> relative fetch (needs scripts/ in cwd) then build.
d="$(newdir)"
cp -r "$ROOT/scripts" "$d/scripts"
mkfake "$d/upstream"
(cd "$d" && env APPSEC_ADVISOR_DEST="$d/upstream" APPSEC_ADVISOR_REF=latest \
  GITSTUB_TAGS="v0.4.0" GITSTUB_IS_CHECKOUT=1 GITSTUB_HAS_ORIGIN=1 \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: SOURCE empty -> fetch+build" 0 "$?"

d="$(newdir)"
mkdir -p "$d/empty"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/empty" timeout 15 bash -x "$PKG") \
  >/dev/null 2>>"$COV"
assert_rc "package: invalid SOURCE -> error" 2 "$?"

d="$(newdir)"
mkfake "$d/src"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" ARCHIVE=1 INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: valid SOURCE ARCHIVE=1" 0 "$?"

d="$(newdir)"
mkfake "$d/src"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" PYSTUB_FAIL=smoke INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" != 0 ]; then pass "package: smoke failure propagates"; else fail "package: smoke failure propagates" "rc=0"; fi

d="$(newdir)"
mkfake "$d/src"
mkdir -p "$d/org-skills/acme-review"
printf '%s\n' 'description: Acme review helper.' >"$d/org-skills/acme-review/SKILL.md"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" PYSTUB_EXPECT_SOURCE_SKILL=acme-review \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: org skill overlay reaches packager" 0 "$?"

d="$(newdir)"
mkfake "$d/src"
mkdir -p "$d/src/skills/acme-review" "$d/org-skills/acme-review"
printf '%s\n' 'description: Upstream skill.' >"$d/src/skills/acme-review/SKILL.md"
printf '%s\n' 'description: Local skill.' >"$d/org-skills/acme-review/SKILL.md"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: org skill cannot overwrite upstream" 2 "$?"

d="$(newdir)"
mkfake "$d/src"
mkdir -p "$d/org-skills/acme-empty"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: org skill requires SKILL.md" 2 "$?"

d="$(newdir)"
mkfake "$d/src"
mkdir -p "$d/org-skills/BadName"
printf '%s\n' 'description: Bad name.' >"$d/org-skills/BadName/SKILL.md"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: org skill name validation" 2 "$?"

# ── init-org-repo.sh ─────────────────────────────────────────────────────────
echo "--- init-org-repo.sh ---"
# answers order: org-name, org-id(default), plugin(default), owner(default),
#                target-dir, demo(y/n), [continue? when dir exists]

# demo=yes; leading empty answer exercises the "(required)" retry on org-name.
d="$(newdir)"
tgt="$d/out"
printf '\nTest Org\n\n\n\n%s\ny\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -f "$tgt/org-profile/requirements.yaml" ] && [ -f "$tgt/org-skills/README.md" ]; then
  pass "init: demo=yes"
else fail "init: demo=yes" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n%s\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ ! -f "$tgt/org-profile/requirements.yaml" ]; then
  pass "init: demo=no"
else fail "init: demo=no" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt"
printf 'Test Org\n\n\n\n%s\nn\ny\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
assert_rc "init: existing dir, continue" 0 "$?"

d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt"
printf 'Test Org\n\n\n\n%s\nn\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
assert_rc "init: existing dir, abort" 1 "$?"

# clone fallback: run a copy with no sibling Makefile; git stub "clones" by
# copying a clean export (tracked files only — no stray device-file dotfiles).
clean="$WORKROOT/export"
mkdir -p "$clean"
("$REAL_GIT" -C "$ROOT" archive HEAD) | tar -x -C "$clean"
lonely="$WORKROOT/lonely"
mkdir -p "$lonely"
cp "$INIT" "$lonely/init-org-repo.sh"
d="$(newdir)"
tgt="$d/out"
printf '\nTest Org\n\n\n\n%s\ny\n' "$tgt" | \
  (cd "$d" && env GITSTUB_CLONE_SRC="$clean" timeout 20 bash -x "$lonely/init-org-repo.sh") \
  >/dev/null 2>>"$COV"
assert_rc "init: clone fallback" 0 "$?"

# ── upstream-check.sh ────────────────────────────────────────────────────────
echo "--- upstream-check.sh ---"
# check_run <name> <expect-rc> <predest 0|1> [VAR=val ...]
# Local checkout sha is abc1234 (GITSTUB_LOCAL_SHA); a bare ls-remote returns
# GITSTUB_REMOTE_SHA (default abc1234) — so same sha == in sync.
check_run() {
  local name="$1" exp="$2" predest="$3"
  shift 3
  local d
  d="$(newdir)"
  [ "$predest" = 1 ] && mkdir -p "$d/dest"
  (cd "$d" && env "$@" APPSEC_ADVISOR_DEST="$d/dest" timeout 15 bash -x "$CHECK") \
    >/dev/null 2>>"$COV"
  assert_rc "$name" "$exp" "$?"
}
check_run "check: latest in sync" 0 1 \
  APPSEC_ADVISOR_REF=latest GITSTUB_TAGS="v0.3.0 v0.4.0" GITSTUB_IS_CHECKOUT=1
check_run "check: pinned tag in sync" 0 1 \
  APPSEC_ADVISOR_REF=v0.4.0 GITSTUB_TAGS="v0.3.0 v0.4.0" GITSTUB_IS_CHECKOUT=1
check_run "check: commit drift" 1 1 \
  APPSEC_ADVISOR_REF=latest GITSTUB_TAGS="v0.4.0" GITSTUB_IS_CHECKOUT=1 GITSTUB_REMOTE_SHA=def5678
check_run "check: latest, no checkout -> nothing to do" 0 0 \
  APPSEC_ADVISOR_REF=latest GITSTUB_TAGS="v0.4.0"
check_run "check: newer release available" 1 1 \
  APPSEC_ADVISOR_REF=v0.3.0 GITSTUB_TAGS="v0.3.0 v0.4.0" GITSTUB_IS_CHECKOUT=1
check_run "check: pinned behind latest, no checkout (CI)" 1 0 \
  APPSEC_ADVISOR_REF=v0.3.0 GITSTUB_TAGS="v0.3.0 v0.4.0"
check_run "check: latest no tags -> error" 2 0 APPSEC_ADVISOR_REF=latest
check_run "check: pinned ref not found -> error" 2 0 \
  APPSEC_ADVISOR_REF=v9.9.9 GITSTUB_TAGS="v0.4.0"

# ── report ───────────────────────────────────────────────────────────────────
echo ""
echo "functional checks: $PASS passed, $FAIL failed"
python3 "$HERE/lib/coverage.py" --trace "$COV" --threshold "$THRESHOLD" \
  --lcov "$ROOT/coverage.lcov" --source-root "$ROOT" \
  "$FETCH" "$PKG" "$INIT" "$CHECK"
covrc=$?

if [ "$FAIL" -eq 0 ] && [ "$covrc" -eq 0 ]; then exit 0; else exit 1; fi
