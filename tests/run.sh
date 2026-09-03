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
# Existing initializer scenarios focus on organization settings and run without
# network access. Pin their upstream explicitly; dedicated cases below exercise
# the new interactive stable/dev selection and release resolution.
export APPSEC_ADVISOR_REF=v0.6.0-beta.1

FETCH="$ROOT/scripts/fetch-upstream.sh"
PKG="$ROOT/scripts/package-local.sh"
INIT="$ROOT/scripts/init-org-repo.sh"
CHECK="$ROOT/scripts/upstream-check.sh"
TEMPLATE_CHECK="$ROOT/scripts/packaging-template-check.sh"
REINIT="$ROOT/scripts/reinit-org-repo.sh"
RELEASE="$ROOT/scripts/release.sh"
GUARD_TEST="$HERE/test_guard.py"
MARKETPLACE_TEST="$HERE/test_local_marketplace.py"
PACKAGED_HELP_TEST="$HERE/test_packaged_help.py"
PACKAGED_README_TEST="$HERE/test_packaged_readme.py"
SESSION_BANNER_PRUNE_TEST="$HERE/test_prune_packaged_session_banner.py"
ARCHIVE_TEST="$HERE/test_archive_built_plugin.py"
BASELINE_UPSTREAM_TEST="$HERE/test_baseline_upstream_check.py"
BASELINE_RESOLVE_TEST="$HERE/test_resolve_baseline_id.py"
PACKAGE_VERSION_TEST="$HERE/test_finalize_package_version.py"
PACKAGED_ORIGINS_TEST="$HERE/test_rewrite_packaged_origins.py"
PACKAGED_PATHS_TEST="$HERE/test_rewrite_packaged_plugin_paths.py"
LATEST_RELEASE_TEST="$HERE/test_select_latest_release.py"
ORG_HOOK_COLLISION_TEST="$HERE/test_org_hook_collisions.py"
RESOLVE_POLICY_TEST="$HERE/test_resolve_package_policy.py"
QUICKSTART_PIN_TEST="$HERE/test_check_quickstart_pin.py"
COMPOSE_BASELINE_TEST="$HERE/test_compose_baseline.py"
SYNC_ORG_BASELINE_TEST="$HERE/test_sync_org_baseline.py"
COVERAGE_TEST="$HERE/test_coverage.py"

# -B: importing guard.py must not leave __pycache__ in org-profile/hooks/,
# which the packager would copy and the smoke test rejects. Preserve every
# unit-test result: this driver intentionally stays out of `set -e` because its
# shell scenarios assert expected failures later on.
UNIT_FAIL=0
run_unit_test() {
  /usr/bin/python3 -B "$1" || UNIT_FAIL=$((UNIT_FAIL + 1))
}
run_unit_test "$GUARD_TEST"
run_unit_test "$MARKETPLACE_TEST"
run_unit_test "$PACKAGED_HELP_TEST"
run_unit_test "$PACKAGED_README_TEST"
run_unit_test "$SESSION_BANNER_PRUNE_TEST"
run_unit_test "$ARCHIVE_TEST"
run_unit_test "$BASELINE_UPSTREAM_TEST"
run_unit_test "$BASELINE_RESOLVE_TEST"
run_unit_test "$PACKAGE_VERSION_TEST"
run_unit_test "$PACKAGED_ORIGINS_TEST"
run_unit_test "$PACKAGED_PATHS_TEST"
run_unit_test "$LATEST_RELEASE_TEST"
run_unit_test "$ORG_HOOK_COLLISION_TEST"
run_unit_test "$RESOLVE_POLICY_TEST"
run_unit_test "$QUICKSTART_PIN_TEST"
run_unit_test "$COMPOSE_BASELINE_TEST"
run_unit_test "$SYNC_ORG_BASELINE_TEST"
run_unit_test "$COVERAGE_TEST"

COV="$(mktemp)"
WORKROOT="$(mktemp -d)"
TRACE_CHILD="$WORKROOT/trace-child.sh"
printf '%s\n' 'set -x' >"$TRACE_CHILD"
PASS=0
FAIL="$UNIT_FAIL"
trap 'rm -rf "$WORKROOT" "$COV"' EXIT

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s  (%s)\n' "$1" "$2"; }
assert_rc() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "rc=$3 want $2"; fi; }
newdir() { mktemp -d "$WORKROOT/d.XXXXXX"; }
mkfake() { # a minimal appsec-advisor checkout
  mkdir -p "$1/.claude-plugin" "$1/scripts" "$1/skills"
  mkdir -p "$(dirname "$1")/org-profile"
  cp "$ROOT/org-profile/org-profile.yaml" "$(dirname "$1")/org-profile/org-profile.yaml"
  printf '%s\n' '{"name":"appsec-advisor","version":"0.6.0-beta.1"}' \
    >"$1/.claude-plugin/plugin.json"
  local f
  for f in package_internal_plugin smoke_test_package; do
    printf '# stub\n' >"$1/scripts/$f.py"
  done
  printf '%s\n' \
    'import os' \
    'def _available_hook_ids(_source):' \
    '    return {item for item in os.environ.get("PYSTUB_UPSTREAM_HOOK_IDS", "").split(",") if item}' \
    'def _available_skills(_source):' \
    '    return {item for item in os.environ.get("PYSTUB_UPSTREAM_SKILL_IDS", "").split(",") if item}' \
    >>"$1/scripts/package_internal_plugin.py"
  printf '%s\n' \
    'import json' \
    'from pathlib import Path' \
    'PLUGIN_ROOT = Path(__file__).resolve().parent.parent' \
    'def _read_plugin_version() -> str:' \
    '    meta = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"' \
    '    if not meta.exists():' \
    '        return "0.0.0"' \
    '    try:' \
    '        return json.loads(meta.read_text()).get("version", "0.0.0")' \
    '    except (json.JSONDecodeError, OSError):' \
    '        return "0.0.0"' \
    >"$1/scripts/validate_org_profile.py"
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
  APPSEC_ADVISOR_URL="https://github.com/appsec-foundry?tab=repositories"
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

# A re-pointed release tag must reach the checkout. Git refuses to overwrite an
# existing local tag without --force, so a fetch without it either fails with
# "would clobber existing tag" or leaves the build on the commit the tag used to
# name.
d="$(newdir)"
mkdir -p "$d/dest"
fetch_log="$d/fetch.log"
(cd "$d" && env APPSEC_ADVISOR_REF=v0.4.0 GITSTUB_TAGS="v0.4.0" \
  GITSTUB_IS_CHECKOUT=1 GITSTUB_HAS_ORIGIN=1 GITSTUB_TAG_MOVED=1 \
  APPSEC_ADVISOR_DEST="$d/dest" timeout 15 bash -x "$FETCH") \
  </dev/null >/dev/null 2>"$fetch_log"
rc=$?
cat "$fetch_log" >>"$COV"
if [ "$rc" = 0 ] && grep -Fq 'WARN: upstream tag v0.4.0 moved from old0000 to def5678' "$fetch_log"; then
  pass "fetch: moved release tag is followed and reported"
else fail "fetch: moved release tag is followed and reported" "rc=$rc"; fi

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
mkdir -p "$d/src/.git"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" ARCHIVE=1 INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -f "$d/dist/acme-appsec-0.1.0.tgz" ] && \
   [ -f "$d/dist/acme-appsec-0.1.0.zip" ] && \
   [ -f "$d/dist/acme-appsec-0.1.0.zip.sha256" ] && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/.claude-plugin/plugin.json | \
     grep -Fq '"appsec_advisor_core_version": "0.6.0-beta.1"' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/.claude-plugin/plugin.json | \
     grep -Fq '"appsec_advisor_core_commit": "abc1234"' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/.claude-plugin/plugin.json | \
     grep -Fq '"appsec_advisor_core_committed_at": "2026-08-23T19:09:53+02:00"' && \
   ! tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/.claude-plugin/plugin.json | \
     grep -Fq 'appsec_advisor_core_ref' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq 'https://raw.githubusercontent.com/appsec-foundry/aiscb/main/secure-coding-baseline.md' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq '"id": "aiscb-0.1.10"' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq '"name": "AI Secure Coding Baseline"' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq '.claude-plugin/package-surface.json' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq 'org-profile/package-policy.yaml' && \
   ! tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq 'githubusercontent.com/matthiasrohr/' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/skills/help/SKILL.md | \
     grep -Fq 'acme-appsec 0.1.0' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/skills/help/SKILL.md | \
     grep -Fq '/acme-appsec:create-threat-model'; then
  pass "package: organization version is used in archive and generated help"
else fail "package: organization version is used in archive and generated help" "rc=$rc"; fi

d="$(newdir)"
cp -r "$ROOT/scripts" "$d/scripts"
mkfake "$d/upstream"
mkdir -p "$d/upstream/.git"
(cd "$d" && env APPSEC_ADVISOR_DEST="$d/upstream" APPSEC_ADVISOR_REF=dev \
  GITSTUB_HEADS="dev" GITSTUB_IS_CHECKOUT=1 GITSTUB_HAS_ORIGIN=1 \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
manifest="$d/build/acme-appsec/.claude-plugin/plugin.json"
if [ "$rc" = 0 ] && [ "$(cat "$d/upstream.ref")" = dev ] && \
   grep -Fq '"appsec_advisor_core_ref": "dev"' "$manifest" && \
   grep -Fq '"appsec_advisor_core_commit": "abc1234"' "$manifest" && \
   grep -Fq 'appsec-advisor core 0.6.0-beta.1 (dev @ abc1234, 2026-08-23)' \
     "$d/build/acme-appsec/skills/help/SKILL.md"; then
  pass "package: branch build records the upstream ref and commit"
else fail "package: branch build records the upstream ref and commit" "rc=$rc"; fi

d="$(newdir)"
mkfake "$d/src"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" PACKAGE_VERSION=01.2.3 \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: invalid organization version is rejected" 2 "$?"

d="$(newdir)"
mkfake "$d/src"
mkdir -p "$d/dist"
printf stale >"$d/dist/acme-appsec-1.2.3.tgz"
printf stale >"$d/dist/acme-appsec-1.2.3.tgz.sha256"
printf stale >"$d/dist/acme-appsec-1.2.3.zip"
printf stale >"$d/dist/acme-appsec-1.2.3.zip.sha256"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" ARCHIVE=1 VERSION=1.2.3 \
  PYSTUB_FAIL=smoke INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" != 0 ] && [ ! -e "$d/dist/acme-appsec-1.2.3.tgz" ] && \
   [ ! -e "$d/dist/acme-appsec-1.2.3.tgz.sha256" ] && \
   [ ! -e "$d/dist/acme-appsec-1.2.3.zip" ] && \
   [ ! -e "$d/dist/acme-appsec-1.2.3.zip.sha256" ]; then
  pass "package: failed rebuild removes stale same-version archive"
else fail "package: failed rebuild removes stale same-version archive" "rc=$rc"; fi

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

# An optional skill is an explicit allowlist entry that may be absent from the
# selected ref: present -> packaged, absent -> skipped, never a failed build.
# The policy in org-profile/ must survive both unchanged.
write_optional_policy() { # write_optional_policy <dir> <optional-name>
  printf '%s\n' 'plugin_surface:' '  skills:' '    include:' '      - help' \
    'optional_skills:' "  - $2" >"$1/org-profile/package-policy.yaml"
}

d="$(newdir)"
mkfake "$d/src"
write_optional_policy "$d" security-score
policy_before="$(cat "$d/org-profile/package-policy.yaml")"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" \
  PYSTUB_UPSTREAM_SKILL_IDS="help,security-score" \
  PYSTUB_EXPECT_POLICY_SKILL=security-score \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$d/org-profile/package-policy.yaml")" = "$policy_before" ]; then
  pass "package: optional skill in the ref is allowlisted, source policy untouched"
else fail "package: optional skill in the ref is allowlisted, source policy untouched" "rc=$rc"; fi

d="$(newdir)"
mkfake "$d/src"
write_optional_policy "$d" security-score
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" \
  PYSTUB_UPSTREAM_SKILL_IDS="help" \
  PYSTUB_REJECT_POLICY_SKILL=security-score \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: optional skill absent from the ref is skipped, not fatal" 0 "$?"

d="$(newdir)"
mkfake "$d/src"
printf '%s\n' 'plugin_surface:' '  skills:' '    include:' '      - help' \
  '      - security-score' 'optional_skills:' '  - security-score' \
  >"$d/org-profile/package-policy.yaml"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" \
  PYSTUB_UPSTREAM_SKILL_IDS="help,security-score" \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: a skill listed as required and optional is rejected" 2 "$?"

d="$(newdir)"
mkfake "$d/src"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" \
  PYSTUB_UPSTREAM_HOOK_IDS=org-block-risky-bash INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: org hook cannot reuse an upstream id" 2 "$?"

# An organization-overlay.md next to the vendored baseline is composed into the
# shipped file on a throwaway copy — the tracked base file must stay untouched.
write_baseline() { # write_baseline <dir>
  mkdir -p "$1/org-profile/baselines"
  printf '%s\n' '# Secure Coding Baseline' '' 'baseline-id: aiscb-0.1.10' '' \
    'RULE-1: do the thing.' >"$1/org-profile/baselines/secure-coding-baseline.md"
}

d="$(newdir)"
mkfake "$d/src"
write_baseline "$d"
printf '%s\n' '## Organization rules' '' 'ORG-1: also do this.' \
  >"$d/org-profile/baselines/organization-overlay.md"
base_before="$(cat "$d/org-profile/baselines/secure-coding-baseline.md")"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
composed="$d/build/acme-appsec/org-profile/baselines/secure-coding-baseline.md"
if [ "$rc" = 0 ] && [ "$(cat "$d/org-profile/baselines/secure-coding-baseline.md")" = "$base_before" ] && \
   grep -Fq 'RULE-1: do the thing.' "$composed" && \
   grep -Fq 'ORG-1: also do this.' "$composed" && \
   [ "$(grep -c '^baseline-id:' "$composed")" = 1 ]; then
  pass "package: baseline overlay is composed without touching the tracked file"
else fail "package: baseline overlay is composed without touching the tracked file" "rc=$rc"; fi

d="$(newdir)"
mkfake "$d/src"
write_baseline "$d"
base_before="$(cat "$d/org-profile/baselines/secure-coding-baseline.md")"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$d/org-profile/baselines/secure-coding-baseline.md")" = "$base_before" ]; then
  pass "package: no overlay file is a clean no-op"
else fail "package: no overlay file is a clean no-op" "rc=$rc"; fi

d="$(newdir)"
mkfake "$d/src"
write_baseline "$d"
printf '%s\n' 'baseline-id: acme-0.1' '' 'ORG-1: also do this.' \
  >"$d/org-profile/baselines/organization-overlay.md"
base_before="$(cat "$d/org-profile/baselines/secure-coding-baseline.md")"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" != 0 ] && [ "$(cat "$d/org-profile/baselines/secure-coding-baseline.md")" = "$base_before" ]; then
  pass "package: overlay with its own baseline-id marker fails the build"
else fail "package: overlay with its own baseline-id marker fails the build" "rc=$rc"; fi

d="$(newdir)"
mkfake "$d/src"
write_baseline "$d"
printf '%s\n' '## A second local overlay' >"$d/org-profile/baselines/organization-overlay.md"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  BASELINE_SOURCE_KIND=organization timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ]; then
  pass "package: organization source rejects a second packaging-repo overlay"
else fail "package: organization source rejects a second packaging-repo overlay" "rc=$rc"; fi

# ── release.sh ───────────────────────────────────────────────────────────────
echo "--- release.sh ---"
RELEASE_BIN="$WORKROOT/release-bin"
mkdir -p "$RELEASE_BIN"
ln -s "$REAL_GIT" "$RELEASE_BIN/git"
printf '%s\n' \
  '#!/bin/sh' \
  'printf "%s\n" "$*" >> "$RELEASE_MAKE_LOG"' \
  'if [ "${RELEASE_MAKE_DIRTY:-0}" = 1 ]; then printf "generated\n" > release-check-output.txt; fi' \
  'exit "${RELEASE_MAKE_RC:-0}"' \
  >"$RELEASE_BIN/make"
chmod +x "$RELEASE_BIN/make"

new_release_repo() {
  RELEASE_CASE="$(newdir)"
  RELEASE_REMOTE="$RELEASE_CASE/remote.git"
  RELEASE_WORK="$RELEASE_CASE/work"
  RELEASE_MAKE_LOG="$RELEASE_CASE/make.log"
  "$REAL_GIT" init -q --bare "$RELEASE_REMOTE"
  "$REAL_GIT" init -q "$RELEASE_WORK"
  "$REAL_GIT" -C "$RELEASE_WORK" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$RELEASE_WORK" config user.name 'Release Test'
  "$REAL_GIT" -C "$RELEASE_WORK" config user.email release@example.test
  printf 'release fixture\n' >"$RELEASE_WORK/README.md"
  "$REAL_GIT" -C "$RELEASE_WORK" add README.md
  "$REAL_GIT" -C "$RELEASE_WORK" commit -q -m initial
  "$REAL_GIT" -C "$RELEASE_WORK" remote add origin "$RELEASE_REMOTE"
  "$REAL_GIT" -C "$RELEASE_WORK" push -q -u origin main
}

release_run() {
  local name="$1" expected="$2" version="$3"
  shift 3
  RELEASE_LAST_LOG="$RELEASE_CASE/release-$PASS-$FAIL.log"
  (cd "$RELEASE_WORK" && env PATH="$RELEASE_BIN:/usr/bin:/bin" \
    RELEASE_MAKE_LOG="$RELEASE_MAKE_LOG" "$@" \
    timeout 20 /bin/bash -x "$RELEASE" "$version") \
    >"$RELEASE_LAST_LOG" 2>&1
  local rc=$?
  cat "$RELEASE_LAST_LOG" >>"$COV"
  assert_rc "$name" "$expected" "$rc"
}

d="$(newdir)"
(cd "$d" && /bin/sh "$RELEASE") >/dev/null 2>&1
assert_rc "release: wrong shell reports Bash requirement" 2 "$?"

RELEASE_CASE="$(newdir)"
RELEASE_WORK="$RELEASE_CASE"
RELEASE_MAKE_LOG="$RELEASE_CASE/make.log"
release_run "release: version is required" 2 ""

RELEASE_LAST_LOG="$RELEASE_CASE/missing-python.log"
(cd "$RELEASE_WORK" && env PATH="$RELEASE_BIN" RELEASE_MAKE_LOG="$RELEASE_MAKE_LOG" \
  /bin/bash -x "$RELEASE" 1.2.3) >"$RELEASE_LAST_LOG" 2>&1
rc=$?
cat "$RELEASE_LAST_LOG" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'releasing requires python3' "$RELEASE_LAST_LOG"; then
  pass "release: missing dependency is reported"
else fail "release: missing dependency is reported" "rc=$rc"; fi

release_run "release: invalid SemVer is rejected" 2 "01.2.3"
release_run "release: repository is required" 2 "1.2.3"

new_release_repo
"$REAL_GIT" -C "$RELEASE_WORK" switch -q -c feature
release_run "release: main branch is required" 2 "1.2.3"

new_release_repo
printf 'dirty\n' >"$RELEASE_WORK/untracked.txt"
release_run "release: dirty worktree is rejected" 2 "1.2.3"

new_release_repo
"$REAL_GIT" -C "$RELEASE_WORK" remote remove origin
release_run "release: origin is required" 2 "1.2.3"

new_release_repo
mv "$RELEASE_REMOTE" "$RELEASE_REMOTE.unavailable"
release_run "release: fetch failure is reported" 2 "1.2.3"

new_release_repo
printf 'ahead\n' >>"$RELEASE_WORK/README.md"
"$REAL_GIT" -C "$RELEASE_WORK" add README.md
"$REAL_GIT" -C "$RELEASE_WORK" commit -q -m ahead
release_run "release: local main must match origin" 2 "1.2.3"

new_release_repo
"$REAL_GIT" -C "$RELEASE_WORK" tag -a v1.2.3 -m existing
release_run "release: existing tag is rejected" 2 "1.2.3"

new_release_repo
release_run "release: failed checks create no tag" 7 "1.2.3" RELEASE_MAKE_RC=7
if ! "$REAL_GIT" -C "$RELEASE_WORK" show-ref --verify --quiet refs/tags/v1.2.3; then
  pass "release: failed checks leave tags unchanged"
else fail "release: failed checks leave tags unchanged" "tag exists"; fi

new_release_repo
release_run "release: check-created changes are rejected" 2 "1.2.3" RELEASE_MAKE_DIRTY=1

new_release_repo
printf '%s\n' '#!/bin/sh' 'exit 1' >"$RELEASE_REMOTE/hooks/pre-receive"
chmod +x "$RELEASE_REMOTE/hooks/pre-receive"
release_run "release: failed push is reported" 1 "1.2.3"
if "$REAL_GIT" -C "$RELEASE_WORK" show-ref --verify --quiet refs/tags/v1.2.3 && \
   ! "$REAL_GIT" --git-dir="$RELEASE_REMOTE" show-ref --verify --quiet refs/tags/v1.2.3 && \
   grep -Fq 'local tag v1.2.3 remains for inspection' "$RELEASE_LAST_LOG"; then
  pass "release: failed push preserves only the local tag"
else fail "release: failed push preserves only the local tag" "unexpected tag state"; fi

new_release_repo
release_run "release: checked tag is pushed" 0 "1.2.3-internal.1"
if "$REAL_GIT" --git-dir="$RELEASE_REMOTE" show-ref --verify --quiet \
     refs/tags/v1.2.3-internal.1 && \
   grep -Fqx -- '--no-print-directory PACKAGE_VERSION=1.2.3-internal.1 VERSION= release-check' \
     "$RELEASE_MAKE_LOG"; then
  pass "release: CI tag and local check use the requested version"
else fail "release: CI tag and local check use the requested version" "tag or make arguments missing"; fi

# MCP servers are declared in the profile's `mcp:` block and written by the
# upstream packager. A leftover org-mcp.json from the previous mechanism must no
# longer be copied over the finished build: it replaced whatever the profile
# produced, including the server selection from package-policy.yaml.
d="$(newdir)"
mkfake "$d/src"
printf '%s\n' '{"mcpServers":{"stale":{"type":"http","url":"https://stale.example"}}}' >"$d/org-mcp.json"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" INTERNAL_NAME=acme-appsec \
  timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && ! grep -q stale "$d/build/acme-appsec/.mcp.json" 2>/dev/null; then
  pass "package: a leftover org-mcp.json no longer overwrites the build"
else fail "package: a leftover org-mcp.json no longer overwrites the build" "rc=$rc"; fi

# ── init-org-repo.sh ─────────────────────────────────────────────────────────
echo "--- init-org-repo.sh ---"
# answers order when APPSEC_ADVISOR_REF is unset: org-name, org-id(default),
#                plugin(default), package-version, owner(default), target-dir,
#                upstream-channel(stable/dev), demo(y/n), baseline(y/n), statusline(y/n),
#                internal-repository-url(optional),
#                [continue? when dir exists], [build(y/n)]

d="$(newdir)"
shell_log="$d/wrong-shell.log"
(cd "$ROOT" && /bin/sh "$INIT") </dev/null >"$shell_log" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -Fq 'initializer requires Bash' "$shell_log"; then
  pass "init: wrong shell reports the required invocation"
else fail "init: wrong shell reports the required invocation" "rc=$rc"; fi

d="$(newdir)"
prereq_log="$d/missing-prerequisites.log"
(cd "$ROOT" && env PATH="$d/no-tools" /bin/bash -x "$INIT") \
  </dev/null >"$prereq_log" 2>&1
rc=$?
cat "$prereq_log" >>"$COV"
if [ "$rc" = 2 ] && \
   grep -Fq 'ERROR: missing required commands: git python3 make sed mktemp' "$prereq_log"; then
  pass "init: missing commands fail early with an actionable error"
else fail "init: missing commands fail early with an actionable error" "rc=$rc"; fi

d="$(newdir)"
prereq_log="$d/old-python.log"
(cd "$ROOT" && env PYSTUB_PYTHON_TOO_OLD=1 timeout 20 bash -x "$INIT") \
  </dev/null >"$prereq_log" 2>&1
rc=$?
cat "$prereq_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'Python 3.10 or newer is required' "$prereq_log"; then
  pass "init: unsupported Python version fails before prompting"
else fail "init: unsupported Python version fails before prompting" "rc=$rc"; fi

d="$(newdir)"
prereq_log="$d/git-identity.log"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\n' "$tgt" | \
  (cd "$ROOT" && env GITSTUB_IDENTITY_MISSING=1 timeout 20 bash -x "$INIT") \
  >"$prereq_log" 2>&1
rc=$?
cat "$prereq_log" >>"$COV"
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'Git author identity is not configured' "$prereq_log"; then
  pass "init: missing Git identity fails before creating the target"
else fail "init: missing Git identity fails before creating the target" "rc=$rc"; fi

d="$(newdir)"
target_log="$d/root-target.log"
printf 'Test Org\n\n\n\n\n/\nn\n\n\n\n' | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$target_log" 2>&1
rc=$?
cat "$target_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'refusing to use a filesystem root' "$target_log"; then
  pass "init: filesystem root target is rejected clearly"
else fail "init: filesystem root target is rejected clearly" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/existing-file"
printf 'not a directory\n' >"$tgt"
target_log="$d/file-target.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$target_log" 2>&1
rc=$?
cat "$target_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'target exists but is not a directory' "$target_log"; then
  pass "init: non-directory target is rejected clearly"
else fail "init: non-directory target is rejected clearly" "rc=$rc"; fi

d="$(newdir)"
mkdir -p "$d/reinit"
reinit_log="$d/invalid-reinit-id.log"
(cd "$ROOT" && env \
  APPSEC_REINIT_TARGET="$d/reinit" APPSEC_REINIT_ORG_NAME='Test Org' \
  APPSEC_REINIT_ORG_ID='Bad ID' APPSEC_REINIT_PLUGIN_NAME='test-appsec' \
  APPSEC_REINIT_PACKAGE_VERSION='1.0.0' APPSEC_REINIT_OWNER='Test Team' \
  APPSEC_REINIT_DEMO=false APPSEC_REINIT_BASELINE=true \
  timeout 20 bash -x "$INIT") >"$reinit_log" 2>&1
rc=$?
cat "$reinit_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'existing organization id must start' "$reinit_log"; then
  pass "init: invalid recovered organization id has a clear error"
else fail "init: invalid recovered organization id has a clear error" "rc=$rc"; fi

# Reinitialization treats persisted source settings as untrusted input too. Each
# organization source mode must fail before touching the existing repository
# when its URL, ref/path tuple, or mode is unsafe.
reinit_source_validation() {
  local kind="$1" url="$2" ref="$3" doc="$4" expected="$5" log="$6"
  (cd "$ROOT" && env \
    APPSEC_REINIT_TARGET="$d/reinit" APPSEC_REINIT_ORG_NAME='Test Org' \
    APPSEC_REINIT_ORG_ID=test APPSEC_REINIT_PLUGIN_NAME=test-appsec \
    APPSEC_REINIT_PACKAGE_VERSION='1.0.0' APPSEC_REINIT_OWNER='Test Team' \
    APPSEC_REINIT_DEMO=false APPSEC_REINIT_BASELINE=true \
    APPSEC_REINIT_BASELINE_KIND="$kind" APPSEC_REINIT_ORG_BASELINE_URL="$url" \
    APPSEC_REINIT_ORG_BASELINE_REF="$ref" APPSEC_REINIT_ORG_BASELINE_DOC="$doc" \
    timeout 20 bash -x "$INIT") >"$log" 2>&1
  rc=$?
  cat "$log" >>"$COV"
  [ "$rc" = 2 ] && grep -Fq "$expected" "$log"
}

source_validation_ok=true
reinit_source_validation organization-git 'file:///unsafe' main dist/baseline.md \
  'existing organization baseline Git URL is unsafe' "$d/reinit-git-url.log" || source_validation_ok=false
reinit_source_validation organization-git 'https://example.test/baseline.git' 'bad..ref' dist/baseline.md \
  'existing organization Git baseline settings are unsafe' "$d/reinit-git-settings.log" || source_validation_ok=false
reinit_source_validation organization-https 'http://example.test/baseline.md' main dist/baseline.md \
  'existing organization baseline HTTPS URL is unsafe' "$d/reinit-https-url.log" || source_validation_ok=false
reinit_source_validation unexpected 'https://example.test/baseline.git' main dist/baseline.md \
  'existing BASELINE_SOURCE_KIND must be' "$d/reinit-kind.log" || source_validation_ok=false
if [ "$source_validation_ok" = true ]; then
  pass "init: unsafe recovered baseline source settings fail closed"
else fail "init: unsafe recovered baseline source settings fail closed"; fi

# Stable is the default channel. Resolve it once and persist the concrete tag so
# a generated repository remains reproducible even after newer tags appear.
d="$(newdir)"
tgt="$d/out"
channel_log="$d/stable-channel.log"
printf 'Test Org\n\n\n\n\n%s\n\nn\n\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && env -u APPSEC_ADVISOR_REF \
    GITSTUB_TAGS='v0.5.0 v0.6.0-beta.1 v0.6.0' timeout 20 bash -x "$INIT") \
  >"$channel_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx 'APPSEC_ADVISOR_REF := v0.6.0' "$tgt/Makefile" && \
   grep -Fqx 'APPSEC_ADVISOR_TEMPLATE_REF ?= aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$tgt/Makefile" && \
   grep -Fq 'Latest stable appsec-advisor release: v0.6.0 (pinned)' "$channel_log"; then
  pass "init: stable channel resolves and pins the latest release"
else fail "init: stable channel resolves and pins the latest release" "rc=$rc"; fi

# Development is deliberately a moving branch ref. An invalid first response
# also verifies that the initializer does not silently select a channel.
d="$(newdir)"
tgt="$d/out"
channel_log="$d/dev-channel.log"
printf 'Test Org\n\n\n\n\n%s\nunknown\n2\nn\n\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && env -u APPSEC_ADVISOR_REF timeout 20 bash -x "$INIT") \
  >"$channel_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx 'APPSEC_ADVISOR_REF := dev' "$tgt/Makefile" && \
   grep -Fq '(enter 1 for stable or 2 for dev)' "$COV"; then
  pass "init: development channel persists the moving dev branch"
else fail "init: development channel persists the moving dev branch" "rc=$rc"; fi

# The automation form APPSEC_ADVISOR_REF=latest has the same reproducible
# semantics as choosing Stable interactively: persist the resolved tag, not the
# moving word "latest".
d="$(newdir)"
tgt="$d/out"
channel_log="$d/latest-override.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && env APPSEC_ADVISOR_REF=latest \
    GITSTUB_TAGS='v0.5.0 v0.7.0' timeout 20 bash -x "$INIT") \
  >"$channel_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx 'APPSEC_ADVISOR_REF := v0.7.0' "$tgt/Makefile" && \
   ! grep -Fqx 'APPSEC_ADVISOR_REF := latest' "$tgt/Makefile" && \
   grep -Fq 'Latest stable appsec-advisor release: v0.7.0 (pinned)' "$channel_log"; then
  pass "init: explicit latest override resolves to a concrete tag"
else fail "init: explicit latest override resolves to a concrete tag" "rc=$rc"; fi

# A configured ref is rendered into a Makefile, so constrain it to a safe Git
# ref token and reject Make syntax even if a remote could technically name such
# a branch or tag.
d="$(newdir)"
tgt="$d/out"
channel_log="$d/unsafe-ref.log"
printf 'Test Org\n\n\n\n\n%s\n' "$tgt" | \
  (cd "$ROOT" && env 'APPSEC_ADVISOR_REF=dev$(shell,id)' \
    timeout 20 bash -x "$INIT") >"$channel_log" 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'APPSEC_ADVISOR_REF is not a valid tag or branch name' "$COV"; then
  pass "init: unsafe upstream ref is rejected before Makefile rendering"
else fail "init: unsafe upstream ref is rejected before Makefile rendering" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\n' "$tgt" | \
  (cd "$ROOT" && env BASELINE_SOURCE_KIND=invalid timeout 20 bash -x "$INIT") \
  >/dev/null 2>"$d/invalid-baseline-kind.err"
rc=$?
cat "$d/invalid-baseline-kind.err" >>"$COV"
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'BASELINE_SOURCE_KIND must be aiscb, organization-git, organization-https, or disabled' \
     "$d/invalid-baseline-kind.err"; then
  pass "init: invalid baseline source mode fails before target creation"
else fail "init: invalid baseline source mode fails before target creation" "rc=$rc"; fi

# Template refs are rendered into Makefiles after resolution. Reject unsafe
# values before fetching and refuse to claim that a dirty source has an exact,
# reproducible commit pin.
d="$(newdir)"
tgt="$d/out"
template_ref_log="$d/unsafe-template-ref.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\n' "$tgt" | \
  (cd "$ROOT" && env 'APPSEC_ADVISOR_TEMPLATE_REF=main$(shell,id)' \
    timeout 20 bash -x "$INIT") >"$template_ref_log" 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'APPSEC_ADVISOR_TEMPLATE_REF is not a safe branch, tag, or commit' "$COV"; then
  pass "init: unsafe template ref is rejected before rendering"
else fail "init: unsafe template ref is rejected before rendering" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
template_dirty_log="$d/dirty-template.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\n' "$tgt" | \
  (cd "$ROOT" && env GITSTUB_TEMPLATE_DIRTY=1 timeout 20 bash -x "$INIT") \
  >"$template_dirty_log" 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'template source has uncommitted or untracked changes' "$COV"; then
  pass "init: dirty template source cannot be recorded as an exact pin"
else fail "init: dirty template source cannot be recorded as an exact pin" "rc=$rc"; fi

# Stable initialization must fail closed when it cannot identify a release;
# falling through to a branch would silently change the selected trust boundary.
d="$(newdir)"
tgt="$d/out"
channel_log="$d/no-release.log"
printf 'Test Org\n\n\n\n\n%s\n\nn\n\n\n\n' "$tgt" | \
  (cd "$ROOT" && env -u APPSEC_ADVISOR_REF timeout 20 bash -x "$INIT") \
  >"$channel_log" 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'no valid v* SemVer appsec-advisor release tags were found' "$COV"; then
  pass "init: stable channel fails closed when no release exists"
else fail "init: stable channel fails closed when no release exists" "rc=$rc"; fi

if ! grep -Eq 'sed -i|\$\{[^}]+\^\^|mapfile' "$INIT" "$REINIT"; then
  pass "init: avoids known GNU sed and Bash 4-only constructs"
else fail "init: avoids known GNU sed and Bash 4-only constructs" "non-portable construct found"; fi

d="$(newdir)"
mkdir -p "$d/incomplete/scripts"
cp "$INIT" "$d/incomplete/scripts/init-org-repo.sh"
printf 'placeholder\n' >"$d/incomplete/Makefile"
tgt="$d/out"
template_log="$d/incomplete-template.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\n' "$tgt" | \
  (cd "$d" && timeout 20 bash -x "$d/incomplete/scripts/init-org-repo.sh") \
  >"$template_log" 2>&1
rc=$?
cat "$template_log" >>"$COV"
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'packaging template is incomplete; missing:' "$template_log"; then
  pass "init: incomplete template has a contextual error before target creation"
else fail "init: incomplete template has a contextual error before target creation" "rc=$rc"; fi

if grep -Fqx '      - session-banner' "$ROOT/org-profile/package-policy.yaml"; then
  pass "policy: session banner is included"
else fail "policy: session banner is included" "missing hook id"; fi

if grep -Fqx '  mcp_servers:' "$ROOT/org-profile/package-policy.yaml"; then
  pass "policy: MCP servers use an explicit allowlist"
else fail "policy: MCP servers use an explicit allowlist" "missing mcp_servers surface"; fi

if grep -Fq 'glab release create "${CI_COMMIT_TAG}"' \
     "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'python:3.11-slim@sha256:9534e5a8e315485d4061ed659af0fd78a284c015f9b73661b41d6bab25604534' \
     "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'registry.gitlab.com/gitlab-org/cli:v1.58.0@sha256:a1bc1b35decb0ceededbb22bb9a8c07eddc1279ab6e9342b32bc42e20333aa7a' \
     "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq -- '--no-install-recommends git make' \
     "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq -- '--use-package-registry' "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'artifacts: true' "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'gh release create "${GITHUB_REF_NAME}"' \
     "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'contents: write' "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'run: make release-package' "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'dist/${{ env.INTERNAL_NAME }}-*.zip' \
     "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'make release-package' "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'dist/${INTERNAL_NAME}-*.zip' "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093' \
     "$ROOT/ci-templates/github/workflows/package.yml"; then
  pass "ci: tagged builds publish tested archives as platform releases"
else fail "ci: tagged builds publish tested archives as platform releases" "release job incomplete"; fi

if grep -Fq 'os: [ubuntu-latest, ubuntu-24.04-arm]' \
     "$ROOT/.github/workflows/ci.yml" && \
   grep -Fq 'package-arm64:' "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'runs-on: ubuntu-24.04-arm' "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'needs: [package, package-arm64]' "$ROOT/ci-templates/github/workflows/package.yml" && \
   grep -Fq 'package-arm64:' "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'saas-linux-small-arm64' "$ROOT/ci-templates/gitlab-ci.yml" && \
   grep -Fq 'job: package-arm64' "$ROOT/ci-templates/gitlab-ci.yml"; then
  pass "ci: amd64 and ARM64 packaging paths are gated"
else fail "ci: amd64 and ARM64 packaging paths are gated" "ARM64 job incomplete"; fi

if grep -Fq 'CPython 3.11 on Linux amd64 and arm64' "$ROOT/ci-requirements.lock" && \
   grep -Fq 'sha256:10892704fc220243f5305762e276552a0395f7beb4dbf9b14ec8fd43b57f126c' \
     "$ROOT/ci-requirements.lock" && \
   grep -Fq 'sha256:acc992ab27b15f852c76755eb2ab7dce86585ddadba6fa5946e58556088845b4' \
     "$ROOT/ci-requirements.lock" && \
   grep -Fq -- '--only-binary=:all:' "$ROOT/ci-requirements.lock"; then
  pass "ci: ARM64 wheels remain hash-pinned and binary-only"
else fail "ci: ARM64 wheels remain hash-pinned and binary-only" "lockfile incomplete"; fi

# The initializer pins the id the published baseline declares, not the one the
# template carries — and keeps the template's when the baseline cannot be read.
d="$(newdir)"
tgt="$d/out"
baseline_log="$d/baseline-pin.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && env PYSTUB_BASELINE_ID=aiscb-9.9.9 timeout 20 bash -x "$INIT") \
  >"$baseline_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx '  id: aiscb-9.9.9' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  file: baselines/secure-coding-baseline.md' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fq 'baseline-id: aiscb-9.9.9' "$tgt/org-profile/baselines/secure-coding-baseline.md" && \
   [ -f "$tgt/org-profile/baselines/secure-coding-baseline.md" ] && \
   grep -Fq '==> Published secure-coding baseline: aiscb-9.9.9 (pinned and vendored)' "$baseline_log"; then
  pass "init: baseline id is pinned from the published baseline"
else fail "init: baseline id is pinned from the published baseline" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && env PYSTUB_FAIL=baseline timeout 20 bash -x "$INIT") \
  >/dev/null 2>"$d/baseline-fail.err"
rc=$?
cat "$d/baseline-fail.err" >>"$COV"
if [ "$rc" = 2 ] && [ ! -e "$tgt" ] && \
   grep -Fq 'could not read the published secure-coding baseline id' "$d/baseline-fail.err"; then
  pass "init: unreadable baseline stops before the repository is created"
else fail "init: unreadable baseline stops before the repository is created" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\nn\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && env PYSTUB_BASELINE_ID=aiscb-9.9.9 timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx '  enabled: false' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  id: aiscb-0.1.10' "$tgt/org-profile/org-profile.yaml" && \
   [ -f "$tgt/org-profile/baselines/secure-coding-baseline.md" ]; then
  pass "init: a declined baseline is not resolved"
else fail "init: a declined baseline is not resolved" "rc=$rc"; fi

# Organization Git mode fetches a configured ref into temporary storage,
# validates it before target creation, copies baseline and skills, removes the
# generic runtime URL, and leaves skills excluded until explicitly allowlisted.
d="$(newdir)"
org_baseline_src="$d/org-baseline"
mkdir -p "$org_baseline_src/dist" "$org_baseline_src/.claude/skills/acme-secure-review"
"$REAL_GIT" -C "$org_baseline_src" init -q -b main
"$REAL_GIT" -C "$org_baseline_src" config user.name Test
"$REAL_GIT" -C "$org_baseline_src" config user.email test@example.test
printf '%s\n' '# Test organization baseline' '' 'baseline-id: test-sec-1.0.0' '' 'Rule.' \
  >"$org_baseline_src/dist/secure-coding-baseline.md"
printf '%s\n' '---' 'name: acme-secure-review' 'description: Test organization skill.' '---' \
  >"$org_baseline_src/.claude/skills/acme-secure-review/SKILL.md"
"$REAL_GIT" -C "$org_baseline_src" add .
"$REAL_GIT" -C "$org_baseline_src" commit -q -m initial
org_baseline_remote="$d/org-baseline.git"
"$REAL_GIT" clone -q --bare "$org_baseline_src" "$org_baseline_remote"
org_fake_ssh="$d/fake-ssh"
printf '%s\n' '#!/usr/bin/env bash' 'exec /usr/bin/git-upload-pack "$ORG_BASELINE_TEST_REMOTE"' \
  >"$org_fake_ssh"
chmod +x "$org_fake_ssh"
org_git_bin="$d/git-bin"
mkdir "$org_git_bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'case " $* " in *" --git-dir "*|*" init --bare "*) exec /usr/bin/git "$@" ;; esac' \
  'exec '"$STUBS"'/git "$@"' >"$org_git_bin/git"
chmod +x "$org_git_bin/git"
tgt="$d/out"
org_init_log="$d/org-init.log"
printf 'Test Org\n\n\n\n\n%s\nn\n2\ngit@example.test:baseline.git\n\ndist/secure-coding-baseline.md\n\n\n\nn\n' \
  "$tgt" | \
  (cd "$ROOT" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" GIT_SSH_VARIANT=ssh \
    ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" timeout 20 bash -x "$INIT") \
  >"$org_init_log" 2>>"$COV"
rc=$?
org_check_rc=0
(cd "$tgt" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" GIT_SSH_VARIANT=ssh \
  ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" make --no-print-directory baseline-sync-check) \
  >>"$org_init_log" 2>&1 || org_check_rc=$?
org_help="$d/org-help.log"
org_help_rc=0
(cd "$tgt" && make --no-print-directory help) >"$org_help" 2>&1 || org_help_rc=$?
if [ "$rc" = 0 ] && [ "$org_check_rc" = 0 ] && [ "$org_help_rc" = 0 ] && \
   grep -Fqx 'BASELINE_SOURCE_KIND ?= organization-git' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_URL ?= git@example.test:baseline.git' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_REF ?= main' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_SOURCE ?=' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_DOC ?= dist/secure-coding-baseline.md' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_SKILLS_DIR ?= .claude/skills' "$tgt/Makefile" && \
   grep -Fqx '  id: test-sec-1.0.0' "$tgt/org-profile/org-profile.yaml" && \
   ! grep -A8 '^baseline:' "$tgt/org-profile/org-profile.yaml" | grep -Fq '  url:' && \
   cmp -s "$org_baseline_src/dist/secure-coding-baseline.md" \
     "$tgt/org-profile/baselines/secure-coding-baseline.md" && \
   [ -f "$tgt/org-skills/acme-secure-review/SKILL.md" ] && \
   grep -Fq '"acme-secure-review"' "$tgt/.org-baseline-sync-state.json" && \
   ! grep -Fqx '      - acme-secure-review' "$tgt/org-profile/package-policy.yaml" && \
   grep -Fq '"kind": "git"' "$tgt/.org-baseline-sync-state.json" && \
   grep -Fq 'ORG_BASELINE_URL=git@example.test:baseline.git' "$org_help" && \
   grep -Fq 'Temporarily fetch URL/ref; copy the composed document and optional skills.' "$org_help" && \
   grep -Fq 'Packaging always uses the tracked reviewed copies' "$org_help" && \
   grep -Fq 'ACCEPT_ID=<id>' "$org_help"; then
  pass "init: organization Git baseline and optional skills are fetched and initialized"
else fail "init: organization Git baseline and optional skills are fetched and initialized" "init_rc=$rc check_rc=$org_check_rc help_rc=$org_help_rc"; fi

git_no_skills_tgt="$d/git-no-skills-out"
printf 'Test Org\n\n\n\n\n%s\nn\n2\ngit@example.test:baseline.git\n\ndist/secure-coding-baseline.md\n\n\nn\nn\n' \
  "$git_no_skills_tgt" | \
  (cd "$ROOT" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" \
    GIT_SSH_VARIANT=ssh ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" \
    timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx 'BASELINE_SOURCE_KIND ?= organization-git' "$git_no_skills_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_SKILLS_DIR ?=' "$git_no_skills_tgt/Makefile" && \
   [ ! -e "$git_no_skills_tgt/org-skills/acme-secure-review" ]; then
  pass "init: a found skill pack is declined and left unsynced"
else fail "init: a found skill pack is declined and left unsynced" "rc=$rc"; fi

# The baseline source is validated before the target directory is touched, so
# an abort would discard every answer already given. A wrong document path is
# asked again with the previous answers as defaults instead.
retry_tgt="$d/retry-out"
printf 'Test Org\n\n\n\n\n%s\nn\n2\ngit@example.test:baseline.git\n\ndist/wrong.md\n\n\n\n\n\ndist/secure-coding-baseline.md\n\nn\n' \
  "$retry_tgt" | \
  (cd "$ROOT" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" \
    GIT_SSH_VARIANT=ssh ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" \
    timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx 'ORG_BASELINE_URL ?= git@example.test:baseline.git' "$retry_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_REF ?= main' "$retry_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_DOC ?= dist/secure-coding-baseline.md' "$retry_tgt/Makefile" && \
   grep -Fqx '  id: test-sec-1.0.0' "$retry_tgt/org-profile/org-profile.yaml"; then
  pass "init: a failed organization baseline fetch is corrected, not discarded"
else fail "init: a failed organization baseline fetch is corrected, not discarded" "rc=$rc"; fi

# `ask` exits its own command substitution only, so input that runs out at the
# retry prompt has to end the run rather than re-ask an empty answer forever.
# The timeout turns a returning loop into a failure instead of a hung suite.
exhausted_tgt="$d/retry-exhausted"
printf 'Test Org\n\n\n\n\n%s\nn\n2\ngit@example.test:baseline.git\n\ndist/wrong.md\n\n\n' \
  "$exhausted_tgt" | \
  (cd "$ROOT" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" \
    GIT_SSH_VARIANT=ssh ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" \
    timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$exhausted_tgt" ]; then
  pass "init: exhausted input at the retry prompt ends the run"
else fail "init: exhausted input at the retry prompt ends the run" "rc=$rc"; fi

printf '%s\n' '# Test organization baseline' '' 'baseline-id: test-sec-1.0.0' '' 'Updated rule.' \
  >"$org_baseline_src/dist/secure-coding-baseline.md"
printf '%s\n' '---' 'name: acme-secure-review' 'description: Updated organization skill.' '---' \
  >"$org_baseline_src/.claude/skills/acme-secure-review/SKILL.md"
"$REAL_GIT" -C "$org_baseline_src" add .
"$REAL_GIT" -C "$org_baseline_src" commit -q -m update
"$REAL_GIT" -C "$org_baseline_src" push -q "$org_baseline_remote" main
org_drift_rc=0
(cd "$tgt" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" \
  GIT_SSH_VARIANT=ssh ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" \
  make --no-print-directory baseline-sync-check) >>"$org_init_log" 2>&1 || org_drift_rc=$?
org_sync_rc=0
(cd "$tgt" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" \
  GIT_SSH_VARIANT=ssh ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" \
  make --no-print-directory baseline-sync) >>"$org_init_log" 2>&1 || org_sync_rc=$?
if [ "$org_drift_rc" = 2 ] && [ "$org_sync_rc" = 0 ] && \
   grep -Fq 'Updated rule.' "$tgt/org-profile/baselines/secure-coding-baseline.md" && \
   grep -Fq 'Updated organization skill.' \
     "$tgt/org-skills/acme-secure-review/SKILL.md"; then
  pass "make: organization Git ref update copies baseline and skills"
else fail "make: organization Git ref update copies baseline and skills" \
  "check_rc=$org_drift_rc sync_rc=$org_sync_rc"; fi

org_reinit_rc=0
(cd "$tgt" && env BASH_ENV="$TRACE_CHILD" APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" REINIT_BUILD=0 \
  timeout 20 bash -x scripts/reinit-org-repo.sh) </dev/null \
  >>"$org_init_log" 2>>"$COV" || org_reinit_rc=$?
if [ "$org_reinit_rc" = 0 ] && \
   grep -Fqx 'BASELINE_SOURCE_KIND ?= organization-git' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_URL ?= git@example.test:baseline.git' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_REF ?= main' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_DOC ?= dist/secure-coding-baseline.md' "$tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_SKILLS_DIR ?= .claude/skills' "$tgt/Makefile"; then
  pass "reinit: organization baseline source settings are preserved"
else fail "reinit: organization baseline source settings are preserved" "rc=$org_reinit_rc"; fi

# Invalid URLs, refs, and source-relative paths are retried; a doc path that is
# safe but does not exist in the source then fails before target creation.
bad_tgt="$d/bad-out"
printf 'Test Org\n\n\n\n\n%s\nn\n2\nfile:///unsafe\ngit@example.test:baseline.git\nbad..ref\nmain\n../escape.md\ndist/does-not-exist.md\n' \
  "$bad_tgt" | \
  (cd "$ROOT" && env PATH="$org_git_bin:$PATH" GIT_SSH_COMMAND="$org_fake_ssh" GIT_SSH_VARIANT=ssh \
    ORG_BASELINE_TEST_REMOTE="$org_baseline_remote" timeout 20 bash -x "$INIT") \
  >/dev/null 2>"$d/org-invalid.err"
rc=$?
cat "$d/org-invalid.err" >>"$COV"
if [ "$rc" = 2 ] && [ ! -e "$bad_tgt" ] && \
   grep -Fq 'enter an HTTPS Git URL without credentials, or an SSH Git URL' "$d/org-invalid.err" && \
   grep -Fq 'enter a safe branch, tag, or commit' "$d/org-invalid.err" && \
   grep -Fq "enter a relative path without '.' or '..' components" "$d/org-invalid.err" && \
   grep -Fq 'baseline document not found as one Git blob' "$d/org-invalid.err"; then
  pass "init: unsafe organization baseline source fails before target creation"
else fail "init: unsafe organization baseline source fails before target creation" "rc=$rc"; fi

# A Git URL over HTTPS offers a personal-access-token prompt; the token must
# reach Git only via a private GIT_ASKPASS helper, override a stale configured
# helper, stay out of xtrace, and leave no temporary helper behind.
d_token="$(newdir)"
token_tgt="$d_token/out"
token_home="$d_token/home"
token_tmp="$d_token/tmp"
token_approved="$d_token/token-approved"
mkdir -p "$token_home" "$token_tmp"
"$REAL_GIT" config --file "$token_home/.gitconfig" credential.helper \
  '!f() { printf "username=stale-user\npassword=stale-value\n"; }; f'
printf 'Test Org\n\n\n\n\n%s\nn\n2\nhttps://git.example.test/baseline.git\n\ndist/secure-coding-baseline.md\nsecret-test-token-xyz\n\n\ny\nn\n' \
  "$token_tgt" | \
  (cd "$ROOT" && env HOME="$token_home" TMPDIR="$token_tmp" \
    PYSTUB_ORG_BASELINE_ID=test-token-1.0.0 PYSTUB_ASSERT_ASKPASS=1 \
    PYSTUB_EXPECT_TOKEN=secret-test-token-xyz GITSTUB_CREDENTIAL_HELPER=manager \
    GITSTUB_CREDENTIAL_APPROVE_MARKER="$token_approved" \
    timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx 'ORG_BASELINE_URL ?= https://git.example.test/baseline.git' "$token_tgt/Makefile" && \
   ! grep -rq 'secret-test-token-xyz' "$token_tgt" && \
   ! grep -Fq 'secret-test-token-xyz' "$COV" && \
   [ -f "$token_approved" ] && \
   [ -z "$(find "$token_tmp" -mindepth 1 -print -quit)" ]; then
  pass "init: a Git HTTPS token exclusively uses GIT_ASKPASS without files or trace output"
else fail "init: a Git HTTPS token exclusively uses GIT_ASKPASS without files or trace output" "rc=$rc"; fi

# A configured plaintext helper is never offered the token, even when the
# fetch itself succeeded with the explicitly entered credential.
d_store="$(newdir)"
store_tgt="$d_store/out"
store_log="$d_store/store.log"
printf 'Test Org\n\n\n\n\n%s\nn\n2\nhttps://git.example.test/baseline.git\n\ndist/secure-coding-baseline.md\nsecret-store-test-token\n\n\nn\n' \
  "$store_tgt" | \
  (cd "$ROOT" && env PYSTUB_ORG_BASELINE_ID=test-store-1.0.0 \
    GITSTUB_CREDENTIAL_HELPER=store timeout 20 bash -x "$INIT") \
  >"$store_log" 2>&1
rc=$?
cat "$store_log" >>"$COV"
if [ "$rc" = 0 ] && \
   grep -Fq "refusing to store the token with Git's plaintext 'store' credential helper" "$store_log" && \
   ! grep -Fq 'secret-store-test-token' "$store_log" && \
   ! grep -rq 'secret-store-test-token' "$store_tgt"; then
  pass "init: plaintext Git credential storage is refused"
else fail "init: plaintext Git credential storage is refused" "rc=$rc"; fi

d_https="$(newdir)"
https_tgt="$d_https/out"
printf 'Test Org\n\n\n\n\n%s\nn\n3\nhttp://unsafe.example.test/baseline.md\nhttps://security.example.test/baseline.md\n\n\nn\n' \
  "$https_tgt" | \
  (cd "$ROOT" && env PYSTUB_ORG_BASELINE_ID=test-https-1.0.0 \
    timeout 20 bash -x "$INIT") >/dev/null 2>"$d_https/https-init.err"
rc=$?
cat "$d_https/https-init.err" >>"$COV"
https_check_rc=0
(cd "$https_tgt" && env PYSTUB_ORG_BASELINE_ID=test-https-1.0.0 \
  make --no-print-directory baseline-sync-check) >/dev/null 2>>"$COV" || https_check_rc=$?
https_help="$d_https/https-help.log"
https_help_rc=0
(cd "$https_tgt" && make --no-print-directory help) >"$https_help" 2>&1 || https_help_rc=$?
if [ "$rc" = 0 ] && [ "$https_check_rc" = 0 ] && [ "$https_help_rc" = 0 ] && \
   grep -Fq 'enter one HTTPS document URL without credentials' "$d_https/https-init.err" && \
   grep -Fqx 'BASELINE_SOURCE_KIND ?= organization-https' "$https_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_URL ?= https://security.example.test/baseline.md' "$https_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_SKILLS_DIR ?=' "$https_tgt/Makefile" && \
   grep -Fqx '  id: test-https-1.0.0' "$https_tgt/org-profile/org-profile.yaml" && \
   ! grep -A8 '^baseline:' "$https_tgt/org-profile/org-profile.yaml" | grep -Fq '  url:' && \
   grep -Fq 'ORG_BASELINE_URL=https://security.example.test/baseline.md' "$https_help" && \
   grep -Fq 'Download exactly one composed HTTPS document; no skills or archives.' "$https_help" && \
   grep -Fq 'baseline-id: test-https-1.0.0' \
     "$https_tgt/org-profile/baselines/secure-coding-baseline.md"; then
  pass "init: one organization HTTPS document is initialized without skills"
else fail "init: one organization HTTPS document is initialized without skills" "rc=$rc help_rc=$https_help_rc"; fi

https_reinit_rc=0
(cd "$https_tgt" && env BASH_ENV="$TRACE_CHILD" APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" REINIT_BUILD=0 \
  timeout 20 bash -x scripts/reinit-org-repo.sh) </dev/null \
  >/dev/null 2>>"$COV" || https_reinit_rc=$?
if [ "$https_reinit_rc" = 0 ] && \
   grep -Fqx 'BASELINE_SOURCE_KIND ?= organization-https' "$https_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_URL ?= https://security.example.test/baseline.md' \
     "$https_tgt/Makefile"; then
  pass "reinit: organization HTTPS source settings are preserved"
else fail "reinit: organization HTTPS source settings are preserved" "rc=$https_reinit_rc"; fi

legacy_tgt="$d/legacy-out"
cp -a "$tgt" "$legacy_tgt"
sed -e 's/^BASELINE_SOURCE_KIND ?=.*/BASELINE_SOURCE_KIND ?= organization/' \
    -e 's|^ORG_BASELINE_SOURCE ?=.*|ORG_BASELINE_SOURCE ?= ../org-baseline|' \
    "$legacy_tgt/Makefile" >"$legacy_tgt/Makefile.new"
mv "$legacy_tgt/Makefile.new" "$legacy_tgt/Makefile"
legacy_reinit_rc=0
(cd "$legacy_tgt" && env BASH_ENV="$TRACE_CHILD" APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" REINIT_BUILD=0 \
  timeout 20 bash -x scripts/reinit-org-repo.sh) </dev/null \
  >/dev/null 2>>"$COV" || legacy_reinit_rc=$?
if [ "$legacy_reinit_rc" = 0 ] && \
   grep -Fqx 'BASELINE_SOURCE_KIND ?= organization' "$legacy_tgt/Makefile" && \
   grep -Fqx 'ORG_BASELINE_SOURCE ?= ../org-baseline' "$legacy_tgt/Makefile"; then
  pass "reinit: legacy local organization source remains supported"
else fail "reinit: legacy local organization source remains supported" "rc=$legacy_reinit_rc"; fi

# demo=yes; leading empty answer exercises the "(required)" retry on org-name.
d="$(newdir)"
tgt="$d/out"
printf '\nTest Org\n\n\n\n\n%s\ny\n\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -f "$tgt/org-profile/requirements.yaml" ] && \
   [ -f "$tgt/org-skills/README.md" ] && \
   [ -f "$tgt/ci-requirements.lock" ] && \
   grep -Fqx '  id: aiscb-0.1.10' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  name: AI Secure Coding Baseline' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  url: https://raw.githubusercontent.com/appsec-foundry/aiscb/main/secure-coding-baseline.md' \
     "$tgt/org-profile/org-profile.yaml" && \
   grep -Fq -- '--require-hashes -r ci-requirements.lock' \
     "$tgt/ci-templates/github/workflows/package.yml" && \
   grep -Fq -- '--require-hashes -r ci-requirements.lock' \
     "$tgt/ci-templates/gitlab-ci.yml"; then
  pass "init: demo=yes"
else fail "init: demo=yes" "rc=$rc"; fi

# Declining the default-on AI Secure Coding Baseline must persist an explicit
# profile setting, while accepting it leaves the plugin's bundled default active.
d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   [ "$(grep -c '^baseline:$' "$tgt/org-profile/org-profile.yaml")" = 1 ] && \
   grep -A1 '^baseline:$' "$tgt/org-profile/org-profile.yaml" | grep -Fqx '  enabled: false'; then
  pass "init: baseline=no"
else fail "init: baseline=no" "rc=$rc"; fi

# Declining the startup status disables the runtime default and removes the
# SessionStart hook from the package allowlist.
d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\n\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -A2 '^banner:' "$tgt/org-profile/org-profile.yaml" | grep -Fqx '  enabled: false' && \
   ! grep -Fqx '      - session-banner' "$tgt/org-profile/package-policy.yaml"; then
  pass "init: startup status=no removes packaged hook"
else fail "init: startup status=no removes packaged hook" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\n\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ ! -f "$tgt/org-profile/requirements.yaml" ]; then
  pass "init: demo=no"
else fail "init: demo=no" "rc=$rc"; fi

# Organization names are UTF-8 input even when the caller's locale is not.
# Preserve the display name while deriving an ASCII-safe technical id.
d="$(newdir)"
tgt="$d/out"
printf 'Prüf+Øvelse+Æble+Ångström\n\n\n\n\n%s\nn\n\n\nhttps://git.example.test/poaa-appsec\n' "$tgt" | \
  (cd "$ROOT" && env LC_ALL=C timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx '  id: poaa' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  name: "Prüf+Øvelse+Æble+Ångström"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  owner: "POAA AppSec Team"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  headline: "POAA AppSec Advisor"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx 'INTERNAL_REPOSITORY_URL ?= https://git.example.test/poaa-appsec' \
     "$tgt/Makefile" && \
   grep -Fq 'Internal packaging repository: [open repository](<https://git.example.test/poaa-appsec>)' \
     "$tgt/README.md" && \
   grep -Fqx 'https://git.example.test/poaa-appsec' "$tgt/.git/remote-origin"; then
  pass "init: UTF-8 organization name"
else fail "init: UTF-8 organization name" "rc=$rc"; fi
unicode_tgt="$tgt"

# Reject malformed terminal bytes instead of writing a profile that fails much
# later during packaging. The second answer also proves YAML metacharacters are
# preserved as data rather than changing the generated document structure.
d="$(newdir)"
tgt="$d/out"
{
  printf 'Pr\303uef Org\n'
  printf 'Prüf: Øvelse # Lab\n'
  printf 'Bad ID\npol\nBad_Name\n\n01.2.3\n1.2.3-internal.1\n\n%s\nn\n\n\nhttp://insecure.example/repo\nhttps://git.example.test/pol-appsec\nn\n' "$tgt"
} | (cd "$ROOT" && env LC_ALL=C timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   /usr/bin/python3 -c 'from pathlib import Path; Path(__import__("sys").argv[1]).read_text(encoding="utf-8")' \
     "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  name: "Prüf: Øvelse # Lab"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  owner: "POL AppSec Team"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fq "start with a lowercase letter or digit; use only lowercase letters, digits, '.', '_' and '-'" "$COV" && \
   grep -Fq "start with a lowercase letter or digit; use only lowercase letters, digits and '-'" "$COV" && \
   grep -Fqx 'PACKAGE_VERSION ?= 1.2.3-internal.1' "$tgt/Makefile" && \
   grep -Fqx 'INTERNAL_REPOSITORY_URL ?= https://git.example.test/pol-appsec' \
     "$tgt/Makefile"; then
  pass "init: invalid UTF-8 and package version are retried safely"
else fail "init: invalid UTF-8 and package version are retried safely" "rc=$rc"; fi

if grep -Fq 'This repository builds and releases the `poaa-appsec`' "$unicode_tgt/README.md" && \
   grep -Fq 'Prüf+Øvelse+Æble+Ångström' "$unicode_tgt/README.md" && \
   grep -Fq 'POAA AppSec Team' "$unicode_tgt/README.md" && \
   grep -Fq '## Maintainer quick start' "$unicode_tgt/README.md" && \
   grep -Fq '## Developer quick start' "$unicode_tgt/README.md" && \
   grep -Fq 'claude --plugin-url "<direct ZIP URL from the release>"' "$unicode_tgt/README.md" && \
   grep -Fq 'docs/MAINTAINER-RUNBOOK.md' "$unicode_tgt/README.md" && \
   grep -Fq 'https://github.com/appsec-foundry/appsec-advisor-packaging-template' \
     "$unicode_tgt/README.md" && \
   grep -Fq '# poaa-appsec maintainer runbook' \
     "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq 'Prüf+Øvelse+Æble+Ångström' \
     "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq 'POAA AppSec Team' "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq '## CI integration' "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq 'make release-package' "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq '## References and lineage' "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq 'APPSEC_ADVISOR_TEMPLATE_URL ?= https://github.com/appsec-foundry/appsec-advisor-packaging-template.git' \
     "$unicode_tgt/Makefile" && \
   grep -Fq 'APPSEC_ADVISOR_URL ?= https://github.com/appsec-foundry/appsec-advisor.git' \
     "$unicode_tgt/Makefile" && \
   ! grep -Fq 'Acme' "$unicode_tgt/README.md" && \
   ! grep -Fq 'Acme' "$unicode_tgt/docs/MAINTAINER-RUNBOOK.md"; then
  pass "init: generated repository docs separate maintainer and developer guidance"
else fail "init: generated repository docs separate maintainer and developer guidance" "placeholder, audience, identity, or lineage mismatch"; fi

# An explicitly accepted initial build runs only after the repository exists
# and writes the actual Claude plugin below build/<plugin-name>/.
d="$(newdir)"
src="$d/upstream-source"
mkfake "$src"
tgt="$d/out"
build_log="$d/build-success.log"
printf 'Test Org\n\n\n2.3.0-internal.1\n\n%s\nn\n\n\nhttps://git.example.test/to-appsec\ny\n' "$tgt" | \
  (cd "$ROOT" && env APPSEC_ADVISOR_SOURCE="$src" timeout 20 bash -x "$INIT") \
  >"$build_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -d "$tgt/.git" ] && [ -d "$tgt/build/to-appsec" ] && \
   grep -Fqx 'PACKAGE_VERSION ?= 2.3.0-internal.1' "$tgt/Makefile" && \
   grep -Fq "vars.PACKAGE_VERSION || '2.3.0-internal.1'" \
     "$tgt/ci-templates/github/workflows/package.yml" && \
   grep -Fqx '  PACKAGE_VERSION: "2.3.0-internal.1"' \
     "$tgt/ci-templates/gitlab-ci.yml" && \
   grep -Fq '"version": "2.3.0-internal.1"' "$tgt/build/to-appsec/.claude-plugin/plugin.json" && \
   grep -Fq 'to-appsec 2.3.0-internal.1' "$tgt/build/to-appsec/skills/help/SKILL.md" && \
   grep -Fq 'maintained by TO AppSec Team' "$tgt/build/to-appsec/README.md" && \
   grep -Fq '/to-appsec:help' "$tgt/build/to-appsec/README.md" && \
   grep -Fq 'https://git.example.test/to-appsec' "$tgt/build/to-appsec/README.md" && \
   grep -Fq 'https://git.example.test/to-appsec' "$tgt/build/to-appsec/skills/help/SKILL.md" && \
   grep -Fq '  2. Customize it for your organization:' "$build_log" && \
   grep -Fq '  3. Rebuild and test the customized plugin:' "$build_log" && \
   grep -Fq '       make package' "$build_log" && \
   grep -Fq '  4. Share it with developers:' "$build_log" && \
   ! grep -Fq '  2. Test the local build:' "$build_log"; then
  pass "init: accepted initial build creates plugin"
else fail "init: accepted initial build creates plugin" "rc=$rc"; fi

# A failed optional build must leave the initialized packaging repository usable
# and tell the operator how to retry it.
d="$(newdir)"
tgt="$d/out"
build_log="$d/build-failure.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\ny\n' "$tgt" | \
  (cd "$ROOT" && env APPSEC_ADVISOR_SOURCE="$d/missing-upstream" \
    timeout 20 bash -x "$INIT") \
  >"$build_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -d "$tgt/.git" ] && \
   grep -Fq 'initial plugin build failed' "$COV" && \
   grep -Fq '  2. Customize it for your organization:' "$build_log" && \
   grep -Fq '  3. Fix the reported build error, then build and test the customized plugin:' "$build_log" && \
   grep -Fq '       make package' "$build_log" && \
   grep -Fq '  4. Share it with developers:' "$build_log"; then
  pass "init: failed initial build preserves repo"
else fail "init: failed initial build preserves repo" "rc=$rc"; fi

# Missing optional build modules are diagnosed before the package scripts can
# fail with an import traceback. The initialized repository remains usable.
d="$(newdir)"
tgt="$d/out"
build_log="$d/build-dependencies.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\ny\n' "$tgt" | \
  (cd "$ROOT" && env PYSTUB_MISSING_BUILD_MODULES='PyYAML jsonschema' \
    timeout 20 bash -x "$INIT") >"$build_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -d "$tgt/.git" ] && [ ! -d "$tgt/build" ] && \
   grep -Fq 'optional plugin build needs these Python packages: PyYAML jsonschema' "$COV" && \
   grep -Fq 'CI installs the reviewed versions from ci-requirements.lock' "$COV"; then
  pass "init: missing Python build modules have a clear recovery path"
else fail "init: missing Python build modules have a clear recovery path" "rc=$rc"; fi

# A Git hook or signing failure must explain that the scaffold and staged files
# remain available instead of ending with only the raw Git error.
d="$(newdir)"
tgt="$d/out"
commit_log="$d/commit-failure.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\n' "$tgt" | \
  (cd "$ROOT" && env GITSTUB_HAS_STAGED_CHANGES=1 GITSTUB_FAIL_COMMIT=1 \
    timeout 20 bash -x "$INIT") >"$commit_log" 2>&1
rc=$?
cat "$commit_log" >>"$COV"
if [ "$rc" = 2 ] && [ -d "$tgt/.git" ] && \
   grep -Fq 'repository was created and files were staged' "$commit_log"; then
  pass "init: failed initial commit preserves scaffold with recovery guidance"
else fail "init: failed initial commit preserves scaffold with recovery guidance" "rc=$rc"; fi

d="$(newdir)"
reinit_prereq_log="$d/reinit-wrong-shell.log"
(cd "$ROOT" && /bin/sh "$REINIT") </dev/null >"$reinit_prereq_log" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -Fq 'reinitialization requires Bash' "$reinit_prereq_log"; then
  pass "reinit: wrong shell reports the supported invocation"
else fail "reinit: wrong shell reports the supported invocation" "rc=$rc"; fi

d="$(newdir)"
reinit_prereq_log="$d/reinit-missing-tools.log"
(cd "$ROOT" && env PATH="$d/no-tools" /bin/bash -x "$REINIT") \
  </dev/null >"$reinit_prereq_log" 2>&1
rc=$?
cat "$reinit_prereq_log" >>"$COV"
if [ "$rc" = 2 ] && \
   grep -Fq 'reinitialization is missing required commands: git python3 mktemp' "$reinit_prereq_log"; then
  pass "reinit: missing commands fail with a contextual error"
else fail "reinit: missing commands fail with a contextual error" "rc=$rc"; fi

d="$(newdir)"
reinit_prereq_log="$d/reinit-old-python.log"
(cd "$ROOT" && env PYSTUB_PYTHON_TOO_OLD=1 timeout 20 bash -x "$REINIT") \
  </dev/null >"$reinit_prereq_log" 2>&1
rc=$?
cat "$reinit_prereq_log" >>"$COV"
if [ "$rc" = 2 ] && \
   grep -Fq 'Python 3.10 or newer is required for reinitialization' "$reinit_prereq_log"; then
  pass "reinit: unsupported Python version fails clearly"
else fail "reinit: unsupported Python version fails clearly" "rc=$rc"; fi

d="$(newdir)"
reinit_prereq_log="$d/reinit-template-root.log"
(cd "$ROOT" && timeout 20 bash -x "$REINIT") </dev/null >"$reinit_prereq_log" 2>&1
rc=$?
cat "$reinit_prereq_log" >>"$COV"
if [ "$rc" = 2 ] && \
   grep -Fq 'this is the packaging template itself' "$reinit_prereq_log"; then
  pass "reinit: the template checkout itself is refused"
else fail "reinit: the template checkout itself is refused" "rc=$rc"; fi

# Declining the optional initial build keeps it as a required next step.
d="$(newdir)"
tgt="$d/out"
build_log="$d/build-skipped.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$build_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fq '  2. Customize it for your organization:' "$build_log" && \
   grep -Fq '  3. Build and test the customized plugin:' "$build_log" && \
   grep -Fq '       make package' "$build_log" && \
   grep -Fq '       claude --plugin-dir' "$build_log" && \
   grep -Fq '       - org-profile/org-profile.yaml' "$build_log" && \
   grep -Fq '       - org-profile/context/organization.md' "$build_log" && \
   grep -Fq '       - org-profile/package-policy.yaml' "$build_log" && \
   grep -Fq '       - org-profile/actors/custom-actors.yaml' "$build_log" && \
   grep -Fq '       - org-profile/hooks/*.py' "$build_log" && \
   grep -Fq '       - org-skills/<skill-id>/SKILL.md' "$build_log" && \
   grep -Fq '       - Makefile' "$build_log" && \
   grep -Fq 'See docs/MAINTAINER-RUNBOOK.md#organization-configuration' "$build_log" && \
   grep -Fq '  4. Share it with developers:' "$build_log" && \
   grep -Fq '       a) make release-package' "$build_log" && \
   grep -Fq '            claude --plugin-url "<direct HTTPS URL to to-appsec-0.1.0.zip>"' "$build_log" && \
   grep -Fq '            claude plugin install to-appsec@<marketplace-name>' "$build_log" && \
   grep -Fq '       make install-local' "$build_log" && \
   grep -Fq 'See docs/MAINTAINER-RUNBOOK.md#releases-and-distribution for rollout options.' "$build_log" && \
   ! grep -Fq 'Further steps (optional):' "$build_log" && \
   ! grep -Fq 'enabled: help, check-permissions' "$build_log"; then
  pass "init: skipped build remains a next step"
else fail "init: skipped build remains a next step" "rc=$rc"; fi
self_contained_tgt="$tgt"

# Exercise the current reinit wrapper itself (rather than the copied scaffold
# wrapper) with the persisted exact commit, including validation and a failed
# fetch boundary.
root_reinit_tgt="$d/root-reinit"
cp -r "$self_contained_tgt" "$root_reinit_tgt"
root_reinit_log="$d/root-reinit.log"
template_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
(cd "$root_reinit_tgt" && env APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  GITSTUB_CLONE_SRC="$ROOT" REINIT_BUILD=0 timeout 20 bash -x "$REINIT") \
  >"$root_reinit_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx "APPSEC_ADVISOR_TEMPLATE_REF ?= $template_commit" "$root_reinit_tgt/Makefile"; then
  pass "reinit: exact template commit is fetched and persisted"
else fail "reinit: exact template commit is fetched and persisted" "rc=$rc"; fi

(cd "$root_reinit_tgt" && env 'APPSEC_ADVISOR_TEMPLATE_REF=main$(shell,id)' \
  REINIT_BUILD=0 timeout 20 bash -x "$REINIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && \
   grep -Fq 'APPSEC_ADVISOR_TEMPLATE_REF is not a safe branch, tag, or commit' "$COV"; then
  pass "reinit: unsafe template ref is rejected"
else fail "reinit: unsafe template ref is rejected" "rc=$rc"; fi

(cd "$root_reinit_tgt" && env APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  APPSEC_ADVISOR_TEMPLATE_URL=http://example.test/template.git \
  REINIT_BUILD=0 timeout 20 bash -x "$REINIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && \
   grep -Fq 'APPSEC_ADVISOR_TEMPLATE_URL must use HTTPS without credentials or an SSH Git URL' "$COV"; then
  pass "reinit: insecure template URL is rejected"
else fail "reinit: insecure template URL is rejected" "rc=$rc"; fi

(cd "$root_reinit_tgt" && env APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  GITSTUB_CLONE_SRC="$ROOT" GITSTUB_FAIL_FETCH=1 REINIT_BUILD=0 \
  timeout 20 bash -x "$REINIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && \
   grep -Fq 'could not fetch pinned packaging-template commit' "$COV"; then
  pass "reinit: failed pinned template fetch stops before refresh"
else fail "reinit: failed pinned template fetch stops before refresh" "rc=$rc"; fi

# make reinit reads identity from the existing repo, keeps differing user-owned
# files by default, reapplies the selected template ref, and can skip packaging.
profile_before="$(cksum "$self_contained_tgt/org-profile/org-profile.yaml")"
readme_before="$(cksum "$self_contained_tgt/README.md")"
printf 'stale infrastructure\n' >"$self_contained_tgt/scripts/package-local.sh"
sed -i 's/^PACKAGE_VERSION ?= 0.1.0$/PACKAGE_VERSION ?= 2.4.0/' \
  "$self_contained_tgt/Makefile"
sed -i 's|^INTERNAL_REPOSITORY_URL ?=$|INTERNAL_REPOSITORY_URL ?= https://git.example.test/to-appsec|' \
  "$self_contained_tgt/Makefile"
sed -i 's/^APPSEC_ADVISOR_REF := .*$/APPSEC_ADVISOR_REF := dev/' \
  "$self_contained_tgt/Makefile"
sed -i '/^      - help$/d; /^      - session-banner$/d' \
  "$self_contained_tgt/org-profile/package-policy.yaml"
sed -i '/^  mcp_servers:/,$d' \
  "$self_contained_tgt/org-profile/package-policy.yaml"
printf '\n# retained organization policy marker\n' >> \
  "$self_contained_tgt/org-profile/package-policy.yaml"
printf '%s\n' \
  'mcp:' \
  '  servers:' \
  '    org-sast:' \
  '      type: http' \
  '      url: https://sast.example.internal/mcp' \
  >>"$self_contained_tgt/org-profile/org-profile.yaml"
profile_before="$(cksum "$self_contained_tgt/org-profile/org-profile.yaml")"
reinit_log="$d/reinit.log"
(cd "$self_contained_tgt" && set -x && export SHELLOPTS && \
  timeout 20 make --no-print-directory GITSTUB_CLONE_SRC="$ROOT" \
    REINIT_BUILD=0 reinit) >"$reinit_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   [ "$profile_before" = "$(cksum "$self_contained_tgt/org-profile/org-profile.yaml")" ] && \
   [ "$readme_before" = "$(cksum "$self_contained_tgt/README.md")" ] && \
   grep -Fqx 'INTERNAL_NAME ?= to-appsec' "$self_contained_tgt/Makefile" && \
   grep -Fqx 'PACKAGE_VERSION ?= 2.4.0' "$self_contained_tgt/Makefile" && \
   grep -Fqx 'INTERNAL_REPOSITORY_URL ?= https://git.example.test/to-appsec' \
     "$self_contained_tgt/Makefile" && \
   grep -Fqx 'APPSEC_ADVISOR_REF := dev' "$self_contained_tgt/Makefile" && \
   grep -Fq 'render-packaged-help.py' "$self_contained_tgt/scripts/package-local.sh" && \
   [ "$(grep -Fxc '      - help' "$self_contained_tgt/org-profile/package-policy.yaml")" = 1 ] && \
   [ "$(grep -Fxc '      - session-banner' "$self_contained_tgt/org-profile/package-policy.yaml")" = 0 ] && \
   [ "$(grep -Fxc '      - org-sast' "$self_contained_tgt/org-profile/package-policy.yaml")" = 1 ] && \
   grep -Fq 'retained organization policy marker' "$self_contained_tgt/org-profile/package-policy.yaml" && \
   grep -Fq 'Re-initialization complete' "$reinit_log" && \
   grep -Fq 'enabled help' "$reinit_log" && \
   grep -Fq '  1. Build the plugin: make package' "$reinit_log" && \
   grep -Fq 'Review and commit the reinitialization changes' "$reinit_log"; then
  pass "reinit: existing settings and user files are preserved"
else
  fail "reinit: existing settings and user files are preserved" "rc=$rc"
fi

# An exclude-based policy enables required surface entries by removing them
# from the exclusion list rather than converting the organization's policy mode.
sed -i '/^  skills:/,/^  hooks:/ s/^    include:/    exclude:/' \
  "$self_contained_tgt/org-profile/package-policy.yaml"
sed -i '/^  hooks:/,/^  mcp_servers:/ s/^    include:/    exclude:/' \
  "$self_contained_tgt/org-profile/package-policy.yaml"
exclude_log="$d/reinit-exclude.log"
(cd "$self_contained_tgt" && env APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" \
  REINIT_BUILD=0 timeout 20 make --no-print-directory reinit) >"$exclude_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fq '    exclude:' "$self_contained_tgt/org-profile/package-policy.yaml" && \
   ! grep -Fq '      - help' "$self_contained_tgt/org-profile/package-policy.yaml" && \
   ! grep -Fq '      - session-banner' "$self_contained_tgt/org-profile/package-policy.yaml" && \
   grep -Fq '      - create-threat-model' "$self_contained_tgt/org-profile/package-policy.yaml" && \
   grep -Fq 'enabled help' "$exclude_log"; then
  pass "reinit: required entries are enabled in an exclude policy"
else fail "reinit: required entries are enabled in an exclude policy" "rc=$rc"; fi

# Changed user-editable files are decided interactively. A single-file yes
# creates a backup, no preserves that file, and "all" applies only to the
# remaining changed files without further prompts.
prompt_tgt="$unicode_tgt"
printf '\n# local guard marker\n' >>"$prompt_tgt/org-profile/hooks/guard.py"
printf '\nlocal organization marker\n' >>"$prompt_tgt/org-profile/context/organization.md"
printf '\nlocal agents marker\n' >>"$prompt_tgt/AGENTS.md"
printf '\nlocal readme marker\n' >>"$prompt_tgt/README.md"
printf '\nlocal runbook marker\n' >>"$prompt_tgt/docs/MAINTAINER-RUNBOOK.md"
prompt_log="$d/reinit-prompts.log"
printf 'y\nn\na\n' | \
  (cd "$prompt_tgt" && set -x && export SHELLOPTS && \
    APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" REINIT_BUILD=0 \
    timeout 20 make --no-print-directory reinit) \
  >"$prompt_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   ! grep -Fq 'local guard marker' "$prompt_tgt/org-profile/hooks/guard.py" && \
   grep -Fq 'local organization marker' "$prompt_tgt/org-profile/context/organization.md" && \
   ! grep -Fq 'local agents marker' "$prompt_tgt/AGENTS.md" && \
   ! grep -Fq 'local readme marker' "$prompt_tgt/README.md" && \
   ! grep -Fq 'local runbook marker' "$prompt_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/org-profile/hooks/guard.py' | wc -l)" = 1 ] && \
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/AGENTS.md' | wc -l)" = 1 ] && \
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/README.md' | wc -l)" = 1 ] && \
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/docs/MAINTAINER-RUNBOOK.md' | wc -l)" = 1 ] && \
   grep -Fq 'updated: '"$prompt_tgt"'/org-profile/hooks/guard.py' "$prompt_log" && \
   grep -Fq 'kept: '"$prompt_tgt"'/org-profile/context/organization.md' "$prompt_log" && \
   grep -Fq 'updated: '"$prompt_tgt"'/AGENTS.md' "$prompt_log" && \
   grep -Fq 'updated: '"$prompt_tgt"'/README.md' "$prompt_log" && \
   grep -Fq 'updated: '"$prompt_tgt"'/docs/MAINTAINER-RUNBOOK.md' "$prompt_log"; then
  pass "reinit: per-file choices and overwrite-all update safely with backups"
else fail "reinit: per-file choices and overwrite-all update safely with backups" "rc=$rc"; fi

# "Keep all" suppresses every later prompt and leaves all differing files in
# place. The already-custom organization context is deliberately the first
# changed file encountered in this second run.
printf '\nsecond local guard marker\n' >>"$prompt_tgt/org-profile/hooks/guard.py"
printf '\nsecond local readme marker\n' >>"$prompt_tgt/README.md"
printf '\nsecond local runbook marker\n' >>"$prompt_tgt/docs/MAINTAINER-RUNBOOK.md"
keep_all_log="$d/reinit-keep-all.log"
printf 'k\n' | \
  (cd "$prompt_tgt" && set -x && export SHELLOPTS && \
    APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" REINIT_BUILD=0 \
    timeout 20 make --no-print-directory reinit) \
  >"$keep_all_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fq 'second local guard marker' "$prompt_tgt/org-profile/hooks/guard.py" && \
   grep -Fq 'local organization marker' "$prompt_tgt/org-profile/context/organization.md" && \
   grep -Fq 'second local readme marker' "$prompt_tgt/README.md" && \
   grep -Fq 'second local runbook marker' "$prompt_tgt/docs/MAINTAINER-RUNBOOK.md" && \
   grep -Fq 'kept: '"$prompt_tgt"'/org-profile/hooks/guard.py' "$keep_all_log" && \
   grep -Fq 'kept: '"$prompt_tgt"'/README.md' "$keep_all_log" && \
   grep -Fq 'kept: '"$prompt_tgt"'/docs/MAINTAINER-RUNBOOK.md' "$keep_all_log"; then
  pass "reinit: keep-all preserves all remaining changed files"
else fail "reinit: keep-all preserves all remaining changed files" "rc=$rc"; fi

# Overwrite choices must never follow a user-owned file symlink outside the
# packaging repository. Reject it before the external target can be changed.
outside_readme="$d/outside-readme.md"
printf 'outside content must remain unchanged\n' >"$outside_readme"
rm "$prompt_tgt/README.md"
ln -s "$outside_readme" "$prompt_tgt/README.md"
symlink_log="$d/reinit-file-symlink.log"
(cd "$prompt_tgt" && set -x && export SHELLOPTS && \
  APPSEC_ADVISOR_TEMPLATE_SOURCE="$ROOT" REINIT_BUILD=0 \
  timeout 20 make --no-print-directory reinit) </dev/null \
  >"$symlink_log" 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && \
   grep -Fqx 'outside content must remain unchanged' "$outside_readme" && \
   grep -Fq 'refusing to replace a symlinked template file' "$COV"; then
  pass "reinit: refuses a user-editable file symlink"
else fail "reinit: refuses a user-editable file symlink" "rc=$rc"; fi

# A reinit wrapper produced before PACKAGE_VERSION existed does not pass that
# setting. The newer initializer must accept it and establish the new default.
d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt"
(cd "$ROOT" && env APPSEC_REINIT_TARGET="$tgt" \
  APPSEC_REINIT_ORG_NAME='Legacy Test Org' APPSEC_REINIT_ORG_ID=lto \
  APPSEC_REINIT_PLUGIN_NAME=lto-appsec APPSEC_REINIT_OWNER='LTO AppSec Team' \
  APPSEC_REINIT_DEMO=false APPSEC_REINIT_BASELINE=true APPSEC_REINIT_BUILD=0 \
  timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && grep -Fqx 'PACKAGE_VERSION ?= 0.1.0' "$tgt/Makefile"; then
  pass "init: legacy reinit wrapper receives the organization version default"
else fail "init: legacy reinit wrapper receives the organization version default" "rc=$rc"; fi

d="$(newdir)"
(cd "$d" && timeout 20 bash -x "$REINIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && grep -Fq 'must run from a scaffolded packaging repository root' "$COV"; then
  pass "reinit: rejects a non-scaffold directory"
else fail "reinit: rejects a non-scaffold directory" "rc=$rc"; fi

d="$(newdir)"
mkdir -p "$d/org-profile"
printf 'INTERNAL_NAME ?= incomplete-appsec\n' >"$d/Makefile"
printf 'organization:\n  id: incomplete\n' >"$d/org-profile/org-profile.yaml"
(cd "$d" && timeout 20 bash -x "$REINIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && grep -Fq 'failed to read existing packaging settings' "$COV"; then
  pass "reinit: rejects incomplete existing settings"
else fail "reinit: rejects incomplete existing settings" "rc=$rc"; fi

(cd "$self_contained_tgt" && env APPSEC_ADVISOR_TEMPLATE_SOURCE="$d/missing-template" \
  timeout 20 bash -x "$REINIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && grep -Fq 'template source does not contain scripts/init-org-repo.sh' "$COV"; then
  pass "reinit: rejects an invalid template source"
else fail "reinit: rejects an invalid template source" "rc=$rc"; fi

# An interactive reinitialization can recover a legacy profile with invalid
# UTF-8 by backing it up before rendering a fresh profile from the entered data.
d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt/org-profile"
printf 'name: Pr\303uef\n' >"$tgt/org-profile/org-profile.yaml"
repair_log="$d/repair.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\ny\ny\nn\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$repair_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   [ -f "$tgt/.reinit-backups/org-profile.yaml.invalid-utf8.bak" ] && \
   [ "$(stat -c %a "$tgt/.reinit-backups")" = 700 ] && \
   grep -Fq 'name: "Test Org"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fq 'backed up:' "$repair_log"; then
  pass "init: reinit backs up and replaces an invalid UTF-8 profile"
else fail "init: reinit backs up and replaces an invalid UTF-8 profile" "rc=$rc"; fi

# Declining recovery preserves the invalid file byte-for-byte and fails before
# packaging rather than silently guessing what the damaged text meant.
d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt/org-profile"
printf 'name: Pr\303uef\n' >"$tgt/org-profile/org-profile.yaml"
invalid_before="$(cksum "$tgt/org-profile/org-profile.yaml")"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\ny\nn\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && \
   [ "$invalid_before" = "$(cksum "$tgt/org-profile/org-profile.yaml")" ] && \
   [ ! -e "$tgt/.reinit-backups" ] && \
   grep -Fq 'is not valid UTF-8 at byte' "$COV"; then
  pass "init: declined UTF-8 recovery leaves the profile unchanged"
else fail "init: declined UTF-8 recovery leaves the profile unchanged" "rc=$rc"; fi

# Recovery must not follow a pre-existing backup-directory symlink outside the
# scaffold when moving the retained user profile.
d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt/org-profile" "$d/outside"
printf 'name: Pr\303uef\n' >"$tgt/org-profile/org-profile.yaml"
invalid_before="$(cksum "$tgt/org-profile/org-profile.yaml")"
ln -s "$d/outside" "$tgt/.reinit-backups"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\ny\ny\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 2 ] && \
   [ "$invalid_before" = "$(cksum "$tgt/org-profile/org-profile.yaml")" ] && \
   [ -z "$(find "$d/outside" -mindepth 1 -print -quit)" ] && \
   grep -Fq 'recovery backup path is not a regular directory' "$COV"; then
  pass "init: UTF-8 recovery rejects a backup-directory symlink"
else fail "init: UTF-8 recovery rejects a backup-directory symlink" "rc=$rc"; fi

# The scaffold must be self-contained: a file that the Makefile, the profile or
# the CI templates reference but init never copies only fails much later, at
# 'make package' / 'make upstream-check' time in the user's repo.
missing=""
for f in scripts/fetch-upstream.sh scripts/upstream-check.sh scripts/packaging-template-check.sh scripts/package-local.sh \
         scripts/prepare-local-marketplace.py scripts/render-packaged-help.py \
         scripts/render-packaged-readme.py scripts/prune-packaged-session-banner.py \
         scripts/baseline-upstream-check.py \
         scripts/select-latest-release.py \
         scripts/check-org-hook-collisions.py \
         scripts/resolve-package-policy.py \
         scripts/archive-built-plugin.py scripts/finalize-package-version.py \
         scripts/rewrite-packaged-origins.py scripts/release.sh \
         scripts/reinit-org-repo.sh scripts/sync-org-baseline.py \
         org-profile/package-policy.yaml org-profile/org-profile.yaml \
         docs/MAINTAINER-RUNBOOK.md ci-requirements.lock Makefile; do
  [ -f "$self_contained_tgt/$f" ] || missing="$missing $f"
done
# every hook script declared in the rendered profile has to exist too
for h in $(sed -n 's|.*org-profile/hooks/\([A-Za-z0-9_.-]*\).*|\1|p' \
             "$self_contained_tgt/org-profile/org-profile.yaml" 2>/dev/null); do
  [ -f "$self_contained_tgt/org-profile/hooks/$h" ] || missing="$missing org-profile/hooks/$h"
done
if [ -z "$missing" ]; then pass "init: scaffold is self-contained"
else fail "init: scaffold is self-contained" "missing:$missing"; fi

d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\ny\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -d "$tgt/.git" ]; then
  pass "init: partial existing dir is initialized and completed"
else fail "init: partial existing dir is initialized and completed" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt"
printf 'Test Org\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
assert_rc "init: existing dir, abort" 1 "$?"

d="$(newdir)"
badarg_log="$d/bad-arg.log"
(cd "$ROOT" && bash -x "$INIT" --bogus) </dev/null >"$badarg_log" 2>&1
rc=$?
cat "$badarg_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'ERROR: unknown argument: --bogus' "$badarg_log"; then
  pass "init: unknown argument is rejected"
else fail "init: unknown argument is rejected" "rc=$rc"; fi

(cd "$ROOT" && bash -x "$INIT" --save-defaults --bogus) </dev/null >"$badarg_log" 2>&1
rc=$?
if [ "$rc" = 2 ] && grep -Fq 'ERROR: unknown argument: --bogus' "$badarg_log"; then
  pass "init: extra arguments are rejected"
else fail "init: extra arguments are rejected" "rc=$rc"; fi

# --save-defaults remembers the organization identity (not the baseline token)
# in a config file under $HOME, and a later run — with or without the flag —
# offers those values as editable defaults instead of requiring them again.
d="$(newdir)"
home1="$d/home1"
mkdir -p "$home1"
tgt1="$d/out1"
printf 'Test Org\n\n\n\n\n%s\nn\n\nn\nhttps://git.example.test/repo1\nn\n' "$tgt1" | \
  (cd "$ROOT" && env HOME="$home1" timeout 20 bash -x "$INIT" --save-defaults) \
  >/dev/null 2>>"$COV"
rc=$?
defaults_file="$home1/.config/appsec-advisor-init/defaults.json"
if [ "$rc" = 0 ] && [ -f "$defaults_file" ] && \
   grep -Fq '"org_name": "Test Org"' "$defaults_file" && \
   grep -Fq '"statusline_enabled": false' "$defaults_file" && \
   grep -Fq '"internal_repository_url": "https://git.example.test/repo1"' "$defaults_file" && \
   ! grep -qi 'token' "$defaults_file" && [ "$(stat -c '%a' "$defaults_file")" = 600 ]; then
  pass "init: --save-defaults persists organization identity, not secrets"
else fail "init: --save-defaults persists organization identity, not secrets" "rc=$rc"; fi

tgt2="$d/out2"
printf '\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt2" | \
  (cd "$ROOT" && env HOME="$home1" timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx '  name: "Test Org"' "$tgt2/org-profile/org-profile.yaml" && \
   grep -A2 '^banner:' "$tgt2/org-profile/org-profile.yaml" | grep -Fqx '  enabled: false' && \
   grep -Fqx 'INTERNAL_REPOSITORY_URL ?= https://git.example.test/repo1' "$tgt2/Makefile"; then
  pass "init: a later run without the flag reuses saved defaults"
else fail "init: a later run without the flag reuses saved defaults" "rc=$rc"; fi

# Saved defaults are parsed as data. A shell fragment or malformed document is
# ignored and cannot execute before the initializer continues with safe prompts.
home_bad="$d/home-bad"
mkdir -p "$home_bad/.config/appsec-advisor-init"
marker="$d/defaults-executed"
printf 'touch %s\n' "$marker" >"$home_bad/.config/appsec-advisor-init/defaults.json"
tgt_bad="$d/out-bad"
bad_defaults_log="$d/bad-defaults.log"
printf 'Safe Org\n\n\n\n\n%s\nn\n\n\n\nn\n' "$tgt_bad" | \
  (cd "$ROOT" && env HOME="$home_bad" timeout 20 bash -x "$INIT") \
  >"$bad_defaults_log" 2>&1
rc=$?
cat "$bad_defaults_log" >>"$COV"
if [ "$rc" = 0 ] && [ ! -e "$marker" ] && \
   grep -Fq 'WARN: ignoring invalid saved defaults' "$bad_defaults_log" && \
   grep -Fqx '  name: "Safe Org"' "$tgt_bad/org-profile/org-profile.yaml"; then
  pass "init: malformed saved defaults are ignored without executing content"
else fail "init: malformed saved defaults are ignored without executing content" "rc=$rc"; fi

# Clone fallback: run a copy with no sibling Makefile. Export tracked and new,
# non-ignored working-tree files so the test covers changes before commit while
# excluding local caches and generated output.
clean="$WORKROOT/export"
mkdir -p "$clean"
(cd "$ROOT" && "$REAL_GIT" ls-files --cached --others --exclude-standard -z | \
  tar --null -T - -cf -) | tar -x -C "$clean"
lonely="$WORKROOT/lonely"
mkdir -p "$lonely"
cp "$INIT" "$lonely/init-org-repo.sh"
d="$(newdir)"
tgt="$d/out"
printf '\nTest Org\n\n\n\n\n%s\ny\n\n' "$tgt" | \
  (cd "$d" && env GITSTUB_CLONE_SRC="$clean" timeout 20 bash -x "$lonely/init-org-repo.sh") \
  >/dev/null 2>>"$COV"
assert_rc "init: clone fallback" 0 "$?"

# A downloaded initializer can also bootstrap from an exact commit. The
# generated repository retains that commit rather than a moving branch name.
d="$(newdir)"
tgt="$d/out"
template_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
printf '\nTest Org\n\n\n\n\n%s\ny\n\n' "$tgt" | \
  (cd "$d" && env GITSTUB_CLONE_SRC="$clean" \
    GITSTUB_TEMPLATE_SHA="$template_commit" \
    APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
    timeout 20 bash -x "$lonely/init-org-repo.sh") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx "APPSEC_ADVISOR_TEMPLATE_REF ?= $template_commit" "$tgt/Makefile"; then
  pass "init: exact template commit fallback remains pinned"
else fail "init: exact template commit fallback remains pinned" "rc=$rc"; fi

# A remotely downloaded initializer may be newer than the selected template
# branch. Optional files added by the newer script must not make an older,
# otherwise self-consistent template snapshot fail during scaffolding.
legacy="$WORKROOT/legacy-export"
cp -r "$clean" "$legacy"
rm "$legacy/scripts/prepare-local-marketplace.py" \
   "$legacy/scripts/rewrite-packaged-origins.py"
d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\n\n' "$tgt" | \
  (cd "$d" && env GITSTUB_CLONE_SRC="$legacy" APPSEC_ADVISOR_TEMPLATE_REF=older-template \
    timeout 20 bash -x "$lonely/init-org-repo.sh") \
  >/dev/null 2>>"$COV"
assert_rc "init: newer script tolerates older template snapshot" 0 "$?"

# A generated repository must ship every template script its own build chain
# calls. The copy list in the initializer is hand-maintained, so a helper that
# lands in the template without being added there only fails much later, inside
# somebody else's repository (that is how compose-baseline.py went missing).
d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\nn\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >/dev/null 2>>"$COV"
rc=$?
scaffold_missing=""
for name in $(grep -ohE '[A-Za-z0-9_.-]+\.(py|sh)' \
    "$tgt/Makefile" "$tgt"/scripts/*.sh 2>/dev/null | sort -u); do
  case "$name" in
    # Guarded in the Makefile: a scaffold carries no quick-start pin to check.
    check-quickstart-pin.py) continue ;;
    # The initializer is fetched, never shipped inside a generated repository.
    init-org-repo.sh) continue ;;
  esac
  # Everything else must come from the template, not from the fetched upstream.
  [ -f "$ROOT/scripts/$name" ] || continue
  [ -f "$tgt/scripts/$name" ] || scaffold_missing="$scaffold_missing $name"
done
if [ "$rc" = 0 ] && [ -z "$scaffold_missing" ]; then
  pass "init: scaffold ships every template script its build chain calls"
else
  fail "init: scaffold ships every template script its build chain calls" \
    "rc=$rc missing:$scaffold_missing"
fi

# Reinitialization does not refetch an organization baseline. It must therefore
# leave both the vendored document and the id the profile pins alone, instead of
# offering the generic baseline this template vendors as a template update.
d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt/org-profile/baselines"
sed 's/^  id: aiscb-.*$/  id: testorg-scb-1.4.0/' \
  "$ROOT/org-profile/org-profile.yaml" >"$tgt/org-profile/org-profile.yaml"
printf 'baseline-id: testorg-scb-1.4.0\n\nOrganization rules.\n' \
  >"$tgt/org-profile/baselines/secure-coding-baseline.md"
org_baseline_reinit_log="$d/org-baseline-reinit.log"
yes a | (cd "$ROOT" && env \
  APPSEC_REINIT_TARGET="$tgt" APPSEC_REINIT_ORG_NAME='Test Org' \
  APPSEC_REINIT_ORG_ID=test APPSEC_REINIT_PLUGIN_NAME=test-appsec \
  APPSEC_REINIT_PACKAGE_VERSION=1.0.0 APPSEC_REINIT_OWNER='Test Team' \
  APPSEC_REINIT_DEMO=false APPSEC_REINIT_BUILD=0 \
  APPSEC_REINIT_BASELINE_KIND=organization-git \
  APPSEC_REINIT_ORG_BASELINE_URL='https://git.example.test/baseline.git' \
  APPSEC_REINIT_ORG_BASELINE_REF=main \
  APPSEC_REINIT_ORG_BASELINE_DOC=dist/secure-coding-baseline.md \
  timeout 20 bash -x "$INIT") >"$org_baseline_reinit_log" 2>>"$COV"
rc=$?
cat "$org_baseline_reinit_log" >>"$COV"
if [ "$rc" = 0 ] && \
   grep -Fqx '  id: testorg-scb-1.4.0' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx 'baseline-id: testorg-scb-1.4.0' \
     "$tgt/org-profile/baselines/secure-coding-baseline.md"; then
  pass "reinit: an organization baseline keeps its document and id"
else fail "reinit: an organization baseline keeps its document and id" "rc=$rc"; fi

# An organization baseline whose id cannot be read is a repository the
# initializer cannot reinitialize correctly. Say so instead of silently pinning
# the template's own id.
d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt/org-profile"
printf 'organization:\n  id: test\n' >"$tgt/org-profile/org-profile.yaml"
missing_id_log="$d/missing-baseline-id.log"
(cd "$ROOT" && env \
  APPSEC_REINIT_TARGET="$tgt" APPSEC_REINIT_ORG_NAME='Test Org' \
  APPSEC_REINIT_ORG_ID=test APPSEC_REINIT_PLUGIN_NAME=test-appsec \
  APPSEC_REINIT_PACKAGE_VERSION=1.0.0 APPSEC_REINIT_OWNER='Test Team' \
  APPSEC_REINIT_DEMO=false APPSEC_REINIT_BUILD=0 \
  APPSEC_REINIT_BASELINE_KIND=organization-https \
  APPSEC_REINIT_ORG_BASELINE_URL='https://security.example.test/baseline.md' \
  timeout 20 bash -x "$INIT") >"$missing_id_log" 2>&1
rc=$?
cat "$missing_id_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'could not read baseline.id' "$missing_id_log"; then
  pass "reinit: an unreadable organization baseline id fails closed"
else fail "reinit: an unreadable organization baseline id fails closed" "rc=$rc"; fi

# Input can run out mid-run (a pipe, a CI job, a closed terminal). Name the
# question that went unanswered rather than ending on a bare `set -e` status.
d="$(newdir)"
eof_log="$d/no-more-input.log"
printf 'Test Org\n' | (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$eof_log" 2>&1
rc=$?
cat "$eof_log" >>"$COV"
if [ "$rc" = 2 ] && grep -Fq 'no more input for a required answer' "$eof_log"; then
  pass "init: exhausted input names the unanswered question"
else fail "init: exhausted input names the unanswered question" "rc=$rc"; fi

# Rendering the template over its own checkout would rewrite the files being
# read. Reject it with an actionable message before anything is created.
d="$(newdir)"
self_target_log="$d/self-target.log"
printf 'Test Org\n\n\n\n\n%s\nn\nn\n\n\n' "$ROOT/." | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$self_target_log" 2>&1
rc=$?
cat "$self_target_log" >>"$COV"
if [ "$rc" = 2 ] && \
   grep -Fq 'target directory is the packaging template itself' "$self_target_log"; then
  pass "init: the template checkout is refused as a target"
else fail "init: the template checkout is refused as a target" "rc=$rc"; fi

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
check_run "check: dev branch in sync ignores release tags" 0 1 \
  APPSEC_ADVISOR_REF=dev GITSTUB_HEADS="dev" GITSTUB_TAGS="v0.4.0" GITSTUB_IS_CHECKOUT=1
check_run "check: dev branch reports moved head" 1 1 \
  APPSEC_ADVISOR_REF=dev GITSTUB_HEADS="dev" GITSTUB_TAGS="v0.4.0" \
  GITSTUB_IS_CHECKOUT=1 GITSTUB_REMOTE_SHA=def5678
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
# An annotated tag resolves to a tag object, not to a commit. Comparing that
# object's sha against the local checkout's commit reports drift on a release
# that never moved.
check_run "check: annotated tag is peeled, not reported as drift" 0 1 \
  APPSEC_ADVISOR_REF=v0.4.0 GITSTUB_TAGS="v0.4.0" GITSTUB_IS_CHECKOUT=1 \
  GITSTUB_REMOTE_SHA=def5678 GITSTUB_TAG_COMMIT_SHA=abc1234
check_run "check: annotated tag that really moved is still drift" 1 1 \
  APPSEC_ADVISOR_REF=v0.4.0 GITSTUB_TAGS="v0.4.0" GITSTUB_IS_CHECKOUT=1 \
  GITSTUB_REMOTE_SHA=def5678 GITSTUB_TAG_COMMIT_SHA=999aaaa

# ── packaging-template-check.sh ─────────────────────────────────────────────
echo "--- packaging-template-check.sh ---"
template_check_run() {
  local name="$1" exp="$2"
  shift 2
  local d
  d="$(newdir)"
  TEMPLATE_CHECK_LAST_LOG="$d/output.log"
  (cd "$d" && env "$@" timeout 15 bash -x "$TEMPLATE_CHECK") \
    >"$TEMPLATE_CHECK_LAST_LOG" 2>>"$COV"
  assert_rc "$name" "$exp" "$?"
}
template_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
new_template_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
template_check_run "template check: pinned commit is current" 0 \
  APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  GITSTUB_REMOTE_SHA="$template_commit"
template_check_run "template check: pinned commit has an update" 1 \
  APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  GITSTUB_REMOTE_SHA="$new_template_commit"
if grep -Fq "make reinit APPSEC_ADVISOR_TEMPLATE_REF=$new_template_commit" \
  "$TEMPLATE_CHECK_LAST_LOG"; then
  pass "template check: update command uses the exact reported commit"
else fail "template check: update command uses the exact reported commit" "moving ref suggested"; fi
template_check_run "template check: invalid remote HEAD fails closed" 2 \
  APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" GITSTUB_REMOTE_SHA=invalid
template_check_run "template check: network query failure is normalized" 2 \
  APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" GITSTUB_FAIL_LS_REMOTE=1
template_check_run "template check: moving branch is reported" 1 \
  APPSEC_ADVISOR_TEMPLATE_REF=main GITSTUB_HEADS=main
template_check_run "template check: current release tag" 0 \
  APPSEC_ADVISOR_TEMPLATE_REF=v0.2.0 GITSTUB_TAGS="v0.1.0 v0.2.0"
template_check_run "template check: newer release tag" 1 \
  APPSEC_ADVISOR_TEMPLATE_REF=v0.1.0 GITSTUB_TAGS="v0.1.0 v0.2.0"
template_check_run "template check: missing ref fails closed" 2 \
  APPSEC_ADVISOR_TEMPLATE_REF=v9.9.9
template_check_run "template check: unsafe ref fails closed" 2 \
  'APPSEC_ADVISOR_TEMPLATE_REF=bad$(shell,id)'
template_check_run "template check: credential URL fails closed" 2 \
  APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  APPSEC_ADVISOR_TEMPLATE_URL=https://user:secret@example.test/template.git
template_check_run "template check: SSH URL is accepted" 0 \
  APPSEC_ADVISOR_TEMPLATE_REF="$template_commit" \
  APPSEC_ADVISOR_TEMPLATE_URL=ssh://git@example.test/template.git \
  GITSTUB_REMOTE_SHA="$template_commit"

# ── report ───────────────────────────────────────────────────────────────────
echo ""
echo "functional checks: $PASS passed, $FAIL failed"
python3 "$HERE/lib/coverage.py" --trace "$COV" --threshold "$THRESHOLD" \
  --lcov "$ROOT/coverage.lcov" --source-root "$ROOT" \
  "$FETCH" "$PKG" "$INIT" "$REINIT" "$RELEASE" "$CHECK" "$TEMPLATE_CHECK"
covrc=$?

if [ "$FAIL" -eq 0 ] && [ "$covrc" -eq 0 ]; then exit 0; else exit 1; fi
