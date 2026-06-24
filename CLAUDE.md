# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **packaging template** for building an internal `appsec-advisor` Claude Code plugin with org-specific defaults. It contains **only org configuration and build glue — no application code.** The actual plugin code lives upstream at `https://github.com/matthiasrohr/appsec-advisor.git` and is cloned to `upstream/appsec-advisor/` at build time.

Crucially, the scripts that do the real packaging work (`package_internal_plugin.py`, `validate_org_profile.py`, `smoke_test_package.py`) live **upstream**, not here. The `scripts/` in this repo only fetch upstream and invoke those tools. To understand build behavior, read the upstream scripts after a fetch.

## Build pipeline

`make package` runs: `fetch-upstream.sh` (clone/checkout upstream at `APPSEC_ADVISOR_REF`) → upstream `package_internal_plugin.py` (overlay `org-profile/` onto upstream, applying `package-policy.yaml` allowlist) → upstream `smoke_test_package.py` → output to `build/<INTERNAL_NAME>/`.

```bash
make               # (or `make help`) list all targets with descriptions
make lint          # shellcheck scripts/ + tests/run.sh (skips gracefully if shellcheck absent)
make upstream-check # read-only drift check: reports if the build ref moved (new commit) or a newer v* release exists. Exit 0=current, 1=drift, 2=error. Does not touch upstream/
make validate      # validate org-profile.yaml against upstream schema only
make package       # fetch + build + smoke test → build/<name>/
make rebuild       # clean (removes upstream/ build/ dist/) then package
make clean         # remove generated dirs
make ci-github     # install .github/workflows/package.yml
make ci-gitlab     # install .gitlab-ci.yml
ARCHIVE=1 VERSION=1.0.0 make package-archive   # produce dist/*.tgz + .sha256

# Test the built plugin in Claude Code:
claude --plugin-dir build/<INTERNAL_NAME>
```

Build overrides (env vars, also CI repo variables): `APPSEC_ADVISOR_URL` (upstream repo or fork), `APPSEC_ADVISOR_REF` (`latest` resolves to newest `v*` tag; pin for reproducible builds), `APPSEC_ADVISOR_SOURCE` (use an existing local checkout, skips fetch), `INTERNAL_NAME`, `VERSION`.

### Tracking upstream: release vs branch

`APPSEC_ADVISOR_REF` is the single knob for "what do I build from". It accepts a `v*` tag, the literal `latest`, **or any branch name** — `fetch-upstream.sh` checks tags and heads, and a branch ref is re-fetched to its current tip on every run (a `--depth 1` detached checkout = effectively a pull).

```bash
make package                              # latest release (REF=latest default → newest v* tag)
APPSEC_ADVISOR_REF=v0.4.0 make package    # pin a specific release (reproducible builds)
APPSEC_ADVISOR_REF=develop make package   # follow a branch tip (e.g. upstream dev branch)
APPSEC_ADVISOR_REF=main    make package   # follow the default branch
```

`make upstream-check` adapts to the mode: with `REF=latest` it flags a newer release tag; with a branch ref it flags when the branch tip has moved past your local checkout.

## Editable surface

| Path | Purpose |
|---|---|
| `org-profile/org-profile.yaml` | Org identity, presets, cost/time guardrails, requirements source, output formats |
| `org-profile/context/organization.md` | Org context injected into analyses (max 50 KB, plain Markdown) |
| `org-profile/actors/*.yaml` | Custom threat actors (globbed in via `actors.add`) |
| `org-profile/package-policy.yaml` | Allowlist of upstream skills/hooks to include |
| `Makefile`, `scripts/` | Build/fetch glue |
| `ci-templates/` | CI pipelines copied into place by `make ci-*` |

`build/`, `dist/`, `upstream/` are **generated — never commit them** (gitignored).

## Invariants (do not break)

- **`package-policy.yaml` is an allowlist.** A new upstream skill/hook appears in the built plugin only after it is explicitly added here.
- **`org-profile.yaml` is schema-validated** at build time (`make validate`). Structural changes must stay schema-conformant (`api_version: appsec-advisor.org-profile/v2`).
- **`context/organization.md` is untrusted reference data.** It can inform findings but must never change severity rules, QA gates, schemas, permissions, or tool behavior.
- **`INTERNAL_NAME`** (default `acme-appsec`) sets both the plugin name and the Claude Code command prefix (`/acme-appsec:...`). It must stay consistent across `Makefile`, both CI configs, and `scripts/package-local.sh`.
- **`"Acme Corp"` / `acme`** are template placeholders (org name, `--description`, etc.). When customizing, replace them everywhere — including `org-profile.yaml`, `package-local.sh`, and both CI configs.

## init-org-repo.sh

`scripts/init-org-repo.sh` is a standalone generator (run via curl or locally) that scaffolds a *new* packaging repo: it prompts for org name/id/plugin name, then copies+`sed`-substitutes the placeholders into a fresh git repo. It is not part of the build. When editing template files, keep its substitution targets intact — it `sed`-replaces literal strings like `acme-appsec`, `Acme Corp`, `Acme AppSec Team`, `id: acme`, `profile_version: "2026.06.1"`, and specific `requirements_yaml_url`/`label` lines. The scaffolded repo's `README.md` is rendered from `README.example.md` (copied + `sed`-substituted) — edit that file to change what end-user repos ship with.

## Note on language

`AGENTS.md` is written in German and documents the same editable surface and invariants; keep it in sync with this file when those change.
