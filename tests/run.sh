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
REINIT="$ROOT/scripts/reinit-org-repo.sh"
GUARD_TEST="$HERE/test_guard.py"
MARKETPLACE_TEST="$HERE/test_local_marketplace.py"
PACKAGED_HELP_TEST="$HERE/test_packaged_help.py"
PACKAGE_VERSION_TEST="$HERE/test_finalize_package_version.py"
PACKAGED_ORIGINS_TEST="$HERE/test_rewrite_packaged_origins.py"

# -B: importing guard.py must not leave __pycache__ in org-profile/hooks/,
# which the packager would copy and the smoke test rejects.
/usr/bin/python3 -B "$GUARD_TEST"
/usr/bin/python3 -B "$MARKETPLACE_TEST"
/usr/bin/python3 -B "$PACKAGED_HELP_TEST"
/usr/bin/python3 -B "$PACKAGE_VERSION_TEST"
/usr/bin/python3 -B "$PACKAGED_ORIGINS_TEST"

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
  mkdir -p "$1/.claude-plugin" "$1/scripts" "$1/skills"
  printf '%s\n' '{"name":"appsec-advisor","version":"0.6.0-beta.1"}' \
    >"$1/.claude-plugin/plugin.json"
  local f
  for f in package_internal_plugin smoke_test_package; do
    printf '# stub\n' >"$1/scripts/$f.py"
  done
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
rc=$?
if [ "$rc" = 0 ] && [ -f "$d/dist/acme-appsec-0.1.0.tgz" ] && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/.claude-plugin/plugin.json | \
     grep -Fq '"appsec_advisor_core_version": "0.6.0-beta.1"' && \
   tar -xOf "$d/dist/acme-appsec-0.1.0.tgz" acme-appsec/config.json | \
     grep -Fq 'https://raw.githubusercontent.com/appsec-foundry/ai-secure-coding-baseline/main/secure-coding-baseline.md' && \
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
mkfake "$d/src"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" PACKAGE_VERSION=01.2.3 \
  INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") >/dev/null 2>>"$COV"
assert_rc "package: invalid organization version is rejected" 2 "$?"

d="$(newdir)"
mkfake "$d/src"
mkdir -p "$d/dist"
printf stale >"$d/dist/acme-appsec-1.2.3.tgz"
printf stale >"$d/dist/acme-appsec-1.2.3.tgz.sha256"
(cd "$d" && env APPSEC_ADVISOR_SOURCE="$d/src" ARCHIVE=1 VERSION=1.2.3 \
  PYSTUB_FAIL=smoke INTERNAL_NAME=acme-appsec timeout 15 bash -x "$PKG") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" != 0 ] && [ ! -e "$d/dist/acme-appsec-1.2.3.tgz" ] && \
   [ ! -e "$d/dist/acme-appsec-1.2.3.tgz.sha256" ]; then
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
# answers order: org-name, org-id(default), plugin(default), package-version,
#                owner(default),
#                target-dir, demo(y/n), baseline(y/n),
#                [continue? when dir exists], [build(y/n)]

if grep -Fqx '      - session-banner' "$ROOT/org-profile/package-policy.yaml"; then
  pass "policy: session banner is included"
else fail "policy: session banner is included" "missing hook id"; fi

# demo=yes; leading empty answer exercises the "(required)" retry on org-name.
d="$(newdir)"
tgt="$d/out"
printf '\nTest Org\n\n\n\n\n%s\ny\n\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -f "$tgt/org-profile/requirements.yaml" ] && [ -f "$tgt/org-skills/README.md" ]; then
  pass "init: demo=yes"
else fail "init: demo=yes" "rc=$rc"; fi

# Declining the default-on AI Secure Coding Baseline must persist an explicit
# profile setting, while accepting it leaves the plugin's bundled default active.
d="$(newdir)"
tgt="$d/out"
printf 'Test Org\n\n\n\n\n%s\nn\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && grep -Fqx '  enabled: false' "$tgt/org-profile/org-profile.yaml"; then
  pass "init: baseline=no"
else fail "init: baseline=no" "rc=$rc"; fi

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
printf 'Prüf+Øvelse+Æble+Ångström\n\n\n\n\n%s\nn\n\n' "$tgt" | \
  (cd "$ROOT" && env LC_ALL=C timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fqx '  id: poaa' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  name: "Prüf+Øvelse+Æble+Ångström"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  owner: "POAA AppSec Team"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  headline: "POAA AppSec Advisor"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  url: "https://github.com/appsec-foundry/appsec-advisor"' \
     "$tgt/org-profile/org-profile.yaml"; then
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
  printf 'pol\n\n01.2.3\n1.2.3-internal.1\n\n%s\nn\n\nn\n' "$tgt"
} | (cd "$ROOT" && env LC_ALL=C timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   /usr/bin/python3 -c 'from pathlib import Path; Path(__import__("sys").argv[1]).read_text(encoding="utf-8")' \
     "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  name: "Prüf: Øvelse # Lab"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx '  owner: "POL AppSec Team"' "$tgt/org-profile/org-profile.yaml" && \
   grep -Fqx 'PACKAGE_VERSION ?= 1.2.3-internal.1' "$tgt/Makefile"; then
  pass "init: invalid UTF-8 and package version are retried safely"
else fail "init: invalid UTF-8 and package version are retried safely" "rc=$rc"; fi

if grep -Fq '`poaa-appsec` is the Claude Code security plugin' "$unicode_tgt/README.md" && \
   grep -Fq 'Prüf+Øvelse+Æble+Ångström' "$unicode_tgt/README.md" && \
   grep -Fq 'POAA AppSec Team' "$unicode_tgt/README.md" && \
   grep -Fq '| `/poaa-appsec:check-permissions` | Enabled |' "$unicode_tgt/README.md" && \
   grep -Fq '| `/poaa-appsec:audit-security-requirements` | Disabled |' "$unicode_tgt/README.md" && \
   grep -Fq 'build/poaa-appsec/config.json' "$unicode_tgt/README.md" && \
   grep -Fq '### Configuration map' "$unicode_tgt/README.md" && \
   grep -Fq 'Organization identity; presets and guardrails; requirements;' "$unicode_tgt/README.md" && \
   grep -Fq 'https://github.com/appsec-foundry/appsec-advisor-packaging-template' \
     "$unicode_tgt/README.md" && \
   grep -Fq 'https://github.com/appsec-foundry/appsec-advisor)' \
     "$unicode_tgt/README.md" && \
   grep -Fq 'APPSEC_ADVISOR_TEMPLATE_URL ?= https://github.com/appsec-foundry/appsec-advisor-packaging-template.git' \
     "$unicode_tgt/Makefile" && \
   grep -Fq 'APPSEC_ADVISOR_URL ?= https://github.com/appsec-foundry/appsec-advisor.git' \
     "$unicode_tgt/Makefile" && \
   ! grep -Fq 'Acme' "$unicode_tgt/README.md"; then
  pass "init: generated README uses organization identity and records repository lineage"
else fail "init: generated README uses organization identity and records repository lineage" "placeholder, identity, or lineage mismatch"; fi

# An explicitly accepted initial build runs only after the repository exists
# and writes the actual Claude plugin below build/<plugin-name>/.
d="$(newdir)"
src="$d/upstream-source"
mkfake "$src"
tgt="$d/out"
build_log="$d/build-success.log"
printf 'Test Org\n\n\n2.3.0-internal.1\n\n%s\nn\n\ny\n' "$tgt" | \
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
   grep -Fq '  4. Load the plugin' "$build_log" && \
   ! grep -Fq '  4. Build the plugin' "$build_log" && \
   ! grep -Fq '  4. Rebuild' "$build_log"; then
  pass "init: accepted initial build creates plugin"
else fail "init: accepted initial build creates plugin" "rc=$rc"; fi

# A failed optional build must leave the initialized packaging repository usable
# and tell the operator how to retry it.
d="$(newdir)"
tgt="$d/out"
build_log="$d/build-failure.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\ny\n' "$tgt" | \
  (cd "$ROOT" && env APPSEC_ADVISOR_SOURCE="$d/missing-upstream" \
    timeout 20 bash -x "$INIT") \
  >"$build_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -d "$tgt/.git" ] && \
   grep -Fq 'initial plugin build failed' "$COV" && \
   grep -Fq '  4. Retry the plugin build: make package' "$build_log" && \
   grep -Fq '  5. Load the plugin' "$build_log"; then
  pass "init: failed initial build preserves repo"
else fail "init: failed initial build preserves repo" "rc=$rc"; fi

# Declining the optional initial build keeps it as a required next step.
d="$(newdir)"
tgt="$d/out"
build_log="$d/build-skipped.log"
printf 'Test Org\n\n\n\n\n%s\nn\n\nn\n' "$tgt" | \
  (cd "$ROOT" && timeout 20 bash -x "$INIT") >"$build_log" 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && \
   grep -Fq '  4. Build the plugin: make package' "$build_log" && \
   grep -Fq '  5. Load the plugin' "$build_log" && \
   grep -Fq 'Further steps (optional):' "$build_log" && \
   grep -Fq '  - Review organization configuration:' "$build_log" && \
   grep -Fq 'presets, requirements, policy, banner/baseline, context, security coach,' "$build_log" && \
   grep -Fq 'actors, abuse cases, hooks, and MCP; see README.md#configuration-map' "$build_log" && \
   grep -Fq '  - Review and customize the default skill selection:' "$build_log" && \
   grep -Fq 'enabled: help, check-permissions, create/update/review/show/ask-threat-model,' "$build_log" && \
   grep -Fq 'disabled: audit-security-requirements, verify-requirements' "$build_log" && \
   grep -Fq 'package-policy.yaml includes/removes skills; org-profile.yaml skill_toggles' "$build_log" && \
   grep -Fq 'enable or disable packaged skills; see README.md#customize-skills' "$build_log" && \
   grep -Fq '  - Distribute the tested plugin through an internal Claude Code Marketplace' "$build_log" && \
   ! grep -Eq '^  [0-9]+\. Optional:' "$build_log" && \
   ! grep -Fq 'Set up CI' "$build_log"; then
  pass "init: skipped build remains a next step"
else fail "init: skipped build remains a next step" "rc=$rc"; fi
self_contained_tgt="$tgt"

# make reinit reads identity from the existing repo, keeps differing user-owned
# files by default, refreshes infrastructure from template main, and can skip packaging.
profile_before="$(cksum "$self_contained_tgt/org-profile/org-profile.yaml")"
readme_before="$(cksum "$self_contained_tgt/README.md")"
printf 'stale infrastructure\n' >"$self_contained_tgt/scripts/package-local.sh"
sed -i 's/^PACKAGE_VERSION ?= 0.1.0$/PACKAGE_VERSION ?= 2.4.0/' \
  "$self_contained_tgt/Makefile"
sed -i '/^      - help$/d; /^      - session-banner$/d' \
  "$self_contained_tgt/org-profile/package-policy.yaml"
printf '\n# retained organization policy marker\n' >> \
  "$self_contained_tgt/org-profile/package-policy.yaml"
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
   grep -Fq 'render-packaged-help.py' "$self_contained_tgt/scripts/package-local.sh" && \
   [ "$(grep -Fxc '      - help' "$self_contained_tgt/org-profile/package-policy.yaml")" = 1 ] && \
   [ "$(grep -Fxc '      - session-banner' "$self_contained_tgt/org-profile/package-policy.yaml")" = 1 ] && \
   grep -Fq 'retained organization policy marker' "$self_contained_tgt/org-profile/package-policy.yaml" && \
   grep -Fq 'Re-initialization complete' "$reinit_log" && \
   grep -Fq 'enabled help, session-banner' "$reinit_log" && \
   grep -Fq '  1. Build the plugin: make package' "$reinit_log" && \
   grep -Fq 'Review and commit the reinitialization changes' "$reinit_log"; then
  pass "reinit: existing settings and user files are preserved"
else fail "reinit: existing settings and user files are preserved" "rc=$rc"; fi

# An exclude-based policy enables required surface entries by removing them
# from the exclusion list rather than converting the organization's policy mode.
sed -i '/^  skills:/,/^  hooks:/ s/^    include:/    exclude:/' \
  "$self_contained_tgt/org-profile/package-policy.yaml"
sed -i '/^  hooks:/,$ s/^    include:/    exclude:/' \
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
   grep -Fq 'enabled help, session-banner' "$exclude_log"; then
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
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/org-profile/hooks/guard.py' | wc -l)" = 1 ] && \
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/AGENTS.md' | wc -l)" = 1 ] && \
   [ "$(find "$prompt_tgt/.reinit-backups" -type f -path '*/README.md' | wc -l)" = 1 ] && \
   grep -Fq 'updated: '"$prompt_tgt"'/org-profile/hooks/guard.py' "$prompt_log" && \
   grep -Fq 'kept: '"$prompt_tgt"'/org-profile/context/organization.md' "$prompt_log" && \
   grep -Fq 'updated: '"$prompt_tgt"'/AGENTS.md' "$prompt_log" && \
   grep -Fq 'updated: '"$prompt_tgt"'/README.md' "$prompt_log"; then
  pass "reinit: per-file choices and overwrite-all update safely with backups"
else fail "reinit: per-file choices and overwrite-all update safely with backups" "rc=$rc"; fi

# "Keep all" suppresses every later prompt and leaves all differing files in
# place. The already-custom organization context is deliberately the first
# changed file encountered in this second run.
printf '\nsecond local guard marker\n' >>"$prompt_tgt/org-profile/hooks/guard.py"
printf '\nsecond local readme marker\n' >>"$prompt_tgt/README.md"
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
   grep -Fq 'kept: '"$prompt_tgt"'/org-profile/hooks/guard.py' "$keep_all_log" && \
   grep -Fq 'kept: '"$prompt_tgt"'/README.md' "$keep_all_log"; then
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
printf 'Test Org\n\n\n\n\n%s\nn\n\ny\ny\nn\n' "$tgt" | \
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
printf 'Test Org\n\n\n\n\n%s\nn\n\ny\nn\n' "$tgt" | \
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
printf 'Test Org\n\n\n\n\n%s\nn\n\ny\ny\n' "$tgt" | \
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
for f in scripts/fetch-upstream.sh scripts/upstream-check.sh scripts/package-local.sh \
         scripts/prepare-local-marketplace.py scripts/render-packaged-help.py \
         scripts/archive-built-plugin.py scripts/finalize-package-version.py \
         scripts/rewrite-packaged-origins.py scripts/reinit-org-repo.sh \
         org-profile/package-policy.yaml org-profile/org-profile.yaml Makefile; do
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
printf 'Test Org\n\n\n\n\n%s\nn\n\ny\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
rc=$?
if [ "$rc" = 0 ] && [ -d "$tgt/.git" ]; then
  pass "init: partial existing dir is initialized and completed"
else fail "init: partial existing dir is initialized and completed" "rc=$rc"; fi

d="$(newdir)"
tgt="$d/out"
mkdir -p "$tgt"
printf 'Test Org\n\n\n\n\n%s\nn\n\nn\n' "$tgt" | (cd "$ROOT" && timeout 20 bash -x "$INIT") \
  >/dev/null 2>>"$COV"
assert_rc "init: existing dir, abort" 1 "$?"

# clone fallback: run a copy with no sibling Makefile; git stub "clones" by
# copying a clean export (tracked files only — no stray device-file dotfiles).
clean="$WORKROOT/export"
mkdir -p "$clean"
("$REAL_GIT" -C "$ROOT" archive HEAD) | tar -x -C "$clean"
# Include newly added source files before they have been committed; once
# tracked, this simply refreshes the archived copy with the working-tree file.
cp "$ROOT/scripts/prepare-local-marketplace.py" \
  "$clean/scripts/prepare-local-marketplace.py"
cp "$ROOT/scripts/render-packaged-help.py" "$clean/scripts/render-packaged-help.py"
cp "$ROOT/scripts/archive-built-plugin.py" "$clean/scripts/archive-built-plugin.py"
cp "$ROOT/scripts/rewrite-packaged-origins.py" \
  "$clean/scripts/rewrite-packaged-origins.py"
cp "$ROOT/scripts/reinit-org-repo.sh" "$clean/scripts/reinit-org-repo.sh"
cp "$ROOT/Makefile" "$clean/Makefile"
lonely="$WORKROOT/lonely"
mkdir -p "$lonely"
cp "$INIT" "$lonely/init-org-repo.sh"
d="$(newdir)"
tgt="$d/out"
printf '\nTest Org\n\n\n\n\n%s\ny\n\n' "$tgt" | \
  (cd "$d" && env GITSTUB_CLONE_SRC="$clean" timeout 20 bash -x "$lonely/init-org-repo.sh") \
  >/dev/null 2>>"$COV"
assert_rc "init: clone fallback" 0 "$?"

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
  "$FETCH" "$PKG" "$INIT" "$REINIT" "$CHECK"
covrc=$?

if [ "$FAIL" -eq 0 ] && [ "$covrc" -eq 0 ]; then exit 0; else exit 1; fi
