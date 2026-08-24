# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **packaging template** for building an internal `appsec-advisor` Claude Code plugin with org-specific defaults. It contains **only org configuration and build glue — no application code.** The actual plugin code lives upstream at `https://github.com/appsec-foundry/appsec-advisor.git` and is cloned to `upstream/appsec-advisor/` at build time.

The core packaging, profile validation, and smoke-test scripts live upstream. The
local `scripts/` directory fetches and invokes that core, then finalizes the
organization version, normalizes known legacy origins, generates package-specific
help and README content, prunes disabled banner code, and optionally archives the
verified result.

## Build pipeline

`make package` runs: fetch the pinned upstream → optionally overlay `org-skills/`
in a temporary source tree → invoke the upstream packager with `org-profile/` and
its allowlist → normalize and finalize the package → validate the resolved core
compatibility → generate packaged help and README → prune disabled banner code →
run the upstream smoke test. Output goes to `build/<INTERNAL_NAME>/`.

`make local-marketplace` adds a generated
`build/.claude-plugin/marketplace.json` around the packaged plugin for local
Marketplace testing. `make install-local` additionally registers that catalog
and installs the plugin with Claude Code's local scope. Neither target modifies
an organization's central Marketplace.

```bash
make               # (or `make help`) list all targets with descriptions
make lint          # shellcheck scripts/ + tests/run.sh (skips gracefully if shellcheck absent)
make test          # shell-script test suite + coverage gate (skips if tests/ absent, e.g. scaffolded repos)
make check         # offline gate: lint + test (no network, no upstream fetch)
make release-check # release-boundary gate: check + check-updates (advisory) + validate + package (builds a clean plugin against upstream)
make upstream-check # read-only drift check: reports if the build ref moved (new commit) or a newer v* release exists. Exit 0=current, 1=drift, 2=error. Does not touch upstream/
make validate      # validate org-profile.yaml against upstream schema only
make package       # fetch + build + smoke test → build/<name>/
make rebuild       # clean (removes upstream/ build/ dist/) then package
make clean         # remove generated dirs, coverage output and local tool caches
make ci-github     # install .github/workflows/package.yml
make ci-gitlab     # install .gitlab-ci.yml
ARCHIVE=1 PACKAGE_VERSION=1.2.0 make package-archive # produce dist/*.tgz + .sha256

# Test the built plugin in Claude Code:
claude --plugin-dir build/<INTERNAL_NAME>
```

Build overrides (env vars, also CI repo variables): `APPSEC_ADVISOR_URL`
(upstream repo or fork), `APPSEC_ADVISOR_REF` (defaults to the pinned release
tag `v0.6.0-beta.1`; `latest` resolves to the newest `v*` tag),
`APPSEC_ADVISOR_SOURCE` (use an existing local checkout, skips fetch),
`ORG_SKILLS_DIR` (defaults to `org-skills`), `INTERNAL_NAME`,
`INTERNAL_REPOSITORY_URL`, `PACKAGE_VERSION`, and the backward-compatible
one-off `VERSION` override.

### Package versioning

`PACKAGE_VERSION` is the organization-owned plugin version. It defaults to
`0.1.0` and is shown in the session banner, packaged help, plugin manifest and
archive filename. It is independent of `APPSEC_ADVISOR_REF`, which pins the
upstream implementation.

```
Acme AppSec Advisor 1.2.0 · /acme-appsec:help
```

Bump `PACKAGE_VERSION` for an internal package release. A packaging-repository
tag such as `v1.2.0` becomes the package version in CI. `VERSION` remains a
one-off compatibility override. The final manifest stores the implementation
separately as `appsec_advisor_core_version`, so `compatibility.core` continues
to validate the upstream core.

### Tracking upstream: release vs branch

`APPSEC_ADVISOR_REF` is the single knob for "what do I build from". It accepts a `v*` tag, the literal `latest`, **or any branch name** — `fetch-upstream.sh` checks tags and heads, and a branch ref is re-fetched to its current tip on every run (a `--depth 1` detached checkout = effectively a pull).

The packaging repository currently uses only `main`, which pins
`APPSEC_ADVISOR_REF=v0.6.0-beta.1`. Raise that pin in the `Makefile` when
upstream tags a new release.

```bash
make package                              # upstream v0.6.0-beta.1 (default)
APPSEC_ADVISOR_REF=latest make package    # follow the newest v* tag instead
APPSEC_ADVISOR_REF=v0.6.0-beta.1 make package # pin a specific release (reproducible builds)
APPSEC_ADVISOR_REF=dev make package       # follow the upstream dev branch
APPSEC_ADVISOR_REF=main    make package   # follow the default branch
```

`make upstream-check` adapts to the mode: with `REF=latest` it flags a newer release tag; with a branch ref it flags when the branch tip has moved past your local checkout.

## Editable surface

| Path | Purpose |
|---|---|
| `org-profile/org-profile.yaml` | Org identity, presets, cost/time guardrails, requirements source, output formats — plus CI gates (`requirements.gate`, `guardrails.fail_on`), run policy (`policy.url_allowlist`), security coaching (`security_coach`), and org hooks (`hooks:`). See upstream [`docs/org-profiles.md`](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md) |
| `org-profile/context/organization.md` | Org context injected into analyses (max 50 KB, plain Markdown) |
| `org-profile/actors/*.yaml` | Custom threat actors (globbed in via `actors.add`) |
| `org-profile/hooks/*.py` | Scripts for org-declared Claude Code hooks (`hooks:` in the profile), referenced via `${CLAUDE_PLUGIN_ROOT}/org-profile/hooks/...` |
| `org-profile/package-policy.yaml` | Allowlist of skills/hooks to include (incl. org hook ids) |
| `org-skills/<skill-id>/SKILL.md` | Optional org-owned skills packaged next to upstream skills |
| `Makefile`, `scripts/` | Build/fetch glue |
| `ci-templates/` | CI pipelines copied into place by `make ci-*` |
| `ci-requirements.lock` | Hashed, binary-only Python dependencies used by CI |

`build/`, `dist/`, `upstream/` are **generated — never commit them** (gitignored).

## Invariants (do not break)

- **`package-policy.yaml` is an allowlist.** A new upstream skill/hook, a local `org-skills/` skill, or an org hook declared in `org-profile.yaml` (`hooks:`) appears in the built plugin only after its id is explicitly added under `plugin_surface.skills`/`hooks`.
- **Org hooks run at Claude Code's event layer only.** The `hooks:` block bundles org scripts (under `org-profile/hooks/`) into the built `hooks/hooks.json` and records them in `package-surface.json` under `hooks.org`. They never reach the analysis pipeline — findings, severity, and schemas stay core-owned.
- **Org skills must not overwrite upstream skills.** `scripts/package-local.sh` fails before packaging if `org-skills/<name>` already exists under the upstream `skills/` directory.
- **`org-profile.yaml` is schema-validated** at build time (`make validate`). Structural changes must stay schema-conformant (`api_version: appsec-advisor.org-profile/v2`).
- **`context/organization.md` is untrusted reference data.** It can inform findings but must never change severity rules, QA gates, schemas, permissions, or tool behavior.
- **MCP servers are declared in `org-profile.yaml` under `mcp:`** and written by the upstream packager, gated by `plugin_surface.mcp_servers`. Tokens and internal URLs must be referenced via `${ENV_VAR}` — never hardcoded; a credential in a server URL is rejected at validation. MCP tool *output* is untrusted like `organization.md`: it can inform findings but must never change severity rules, permissions, or tool behavior. An `org-mcp.json` at the repo root is no longer read; it used to be copied over the finished build and silently replaced the profile's servers.
- **`INTERNAL_NAME`** (default `acme-appsec`) sets both the plugin name and the Claude Code command prefix (`/acme-appsec:...`). It must stay consistent across `Makefile`, both CI configs, and `scripts/package-local.sh`.
- **`"Acme Corp"` / `acme`** are template placeholders (org name, `--description`, etc.). When customizing, replace them everywhere — including `org-profile.yaml`, `package-local.sh`, and both CI configs.

## init-org-repo.sh

`scripts/init-org-repo.sh` is a standalone generator (run via curl or locally) that scaffolds a *new* packaging repo: it prompts for org name/id/plugin name, then copies+`sed`-substitutes the placeholders into a fresh git repo. It is not part of the build. When editing template files, keep its substitution targets intact — it `sed`-replaces literal strings like `acme-appsec`, `Acme Corp`, `Acme AppSec Team`, `id: acme`, `profile_version: "2026.06.1"`, and specific `requirements_yaml_url`/`label` lines. The scaffolded repo's `README.md` is rendered from `README.example.md` (copied + `sed`-substituted) — edit that file to change what end-user repos ship with.

## Agent guidance

`AGENTS.md` contains the repository-wide operating instructions and the same
editable-surface invariants. Keep this Claude Code-specific summary consistent
with it when build behavior changes.
