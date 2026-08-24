# appsec-advisor — Org Packaging Template

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-5A67D8.svg)](https://docs.claude.com/en/docs/claude-code)
[![codecov](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template/graph/badge.svg)](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template)
[![Upstream](https://img.shields.io/badge/upstream-appsec--advisor-orange.svg)](https://github.com/appsec-foundry/appsec-advisor)

Template repo for building an internal [`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor) Claude Code plugin with your own org-specific defaults, requirements catalog, and cost guardrails.

See [the developer documentation](docs/DEVELOPMENT.md) for the development
workflow.

## Quick Start

**Prerequisites:** `git`, `python3` (3.10+), `make`

**1. Create your packaging repo**

Run the init script — it asks for your org name and plugin name, creates a
ready-to-use git repo, and offers to build the plugin immediately:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
```

Alternatively, click **Use this template** on GitHub and replace `Acme Corp` / `acme-appsec` manually.

**2. Edit your org profile**

Open `org-profile/org-profile.yaml` in your new repo. If you used the init script, `organization.id`, `.name`, `.profile_version`, and `.owner` are already filled in. The one thing to update manually:

- Point `requirements.source.requirements_yaml_url` to your internal requirements catalog, or remove that block if you don't have one yet.

If you used the GitHub Template instead, also replace `organization.id`, `.name`, `.profile_version`, and `.owner` with your values.

**3. Set up CI for your platform** — run one of:

```bash
make ci-github   # copies ci-templates/github/workflows/package.yml → .github/workflows/
make ci-gitlab   # copies ci-templates/gitlab-ci.yml → .gitlab-ci.yml
```

Then set `INTERNAL_NAME` to your plugin name in the CI repository variables if it differs from the default.

**4. Build the plugin locally:**

```bash
make package
```

This fetches the upstream plugin, overlays your org profile, runs a smoke test, and writes the result to `build/your-plugin-name/`. To force a clean rebuild:

```bash
make rebuild
```

**5. Load it in Claude Code:**

```bash
claude --plugin-dir build/your-plugin-name
```

**6. Run your first threat model:**

```text
/your-plugin-name:check-permissions --update
/your-plugin-name:create-threat-model
```

For CI, tagging a release triggers the pipeline from step 3 automatically.

## Customization

Beyond the quick start, these files are yours to edit:

| File | Purpose |
|---|---|
| `org-profile/org-profile.yaml` | Presets, cost guardrails, requirements source, output formats |
| `org-profile/context/organization.md` | Short org context injected into analyses (max 50 KB) |
| `org-profile/actors/*.yaml` | Custom threat actors for threat models — edit or delete |
| `org-profile/package-policy.yaml` | Allowlist of which skills and hooks to include |
| `org-skills/<skill-id>/SKILL.md` | Optional organization-owned skills shipped next to upstream skills |
| `org-profile/org-profile.yaml` → `mcp:` | Optional MCP servers (e.g. internal SAST/SCA endpoints), written into the built plugin's `.mcp.json` — secrets via `${ENV_VAR}` only |

`build/`, `dist/`, and `upstream/` are all generated — do not commit them.

### Add your own skills

Keep upstream as the source of truth, and put organization-owned skills under
`org-skills/`:

```text
org-skills/
└── acme-architecture-review/
    └── SKILL.md
```

`make package` copies those skills into a temporary upstream source tree before
the upstream packager runs. The checkout in `upstream/` is left untouched.

Two rules keep this predictable:

- Do not reuse an upstream skill name. The build fails if a local skill would
  overwrite `upstream/appsec-advisor/skills/<same-name>`.
- If `org-profile/package-policy.yaml` uses `plugin_surface.skills.include`,
  add the local skill name there as well. The allowlist covers both upstream and
  organization skills.

## Build Reference

```bash
# Validate org profile only
make validate

# Fetch upstream + build + smoke test
make package

# Override the upstream release pinned by main
APPSEC_ADVISOR_REF=v0.6.0-beta.1 make package

# Force a clean rebuild (removes upstream/, build/, dist/ first)
make rebuild

# Remove all generated directories
make clean

# Read-only drift check (newer release, or branch tip moved past local build)
make upstream-check

# Pin a specific upstream release
APPSEC_ADVISOR_REF=v0.6.0-beta.1 make package

# Follow a different branch tip (re-pulled to its tip on each build)
APPSEC_ADVISOR_REF=main make package

# Build a distributable archive (.tgz + .sha256)
ARCHIVE=1 VERSION=1.0.0 make package-archive

# Use an existing local upstream checkout
APPSEC_ADVISOR_SOURCE=/path/to/local/appsec-advisor make package

# Generate build/.claude-plugin/marketplace.json for local marketplace testing
make local-marketplace

# Register that generated marketplace and install the plugin locally
make install-local
```

`install-local` uses the marketplace name `<plugin-name>-local` and Claude
Code's `local` installation scope. Override these with
`LOCAL_MARKETPLACE_NAME` and `LOCAL_MARKETPLACE_SCOPE` when needed. The
generated catalog lives under `build/`; it is only a local test adapter and
does not replace your organization's existing marketplace.

## CI

Run `make ci-github` or `make ci-gitlab` to install the CI pipeline (see Quick Start step 3). Both do the same as the local build: fetch upstream, build, smoke test, and upload the `.tgz` with its `.sha256` as a build artifact. The pipeline triggers on `v*` tags and `workflow_dispatch`.

| Variable | Default | Description |
|---|---|---|
| `APPSEC_ADVISOR_URL` | upstream GitHub | Upstream repo or internal fork |
| `APPSEC_ADVISOR_REF` | `v0.6.0-beta.1` | Pinned upstream release; explicitly set it to override |
| `INTERNAL_NAME` | `acme-appsec` | Plugin name and Claude Code command namespace |
| `VERSION` | derived from git tag or commit SHA | Version of the produced package |

## Related Projects

- [appsec-advisor](https://github.com/appsec-foundry/appsec-advisor) — upstream Claude Code plugin this template packages
- [appsec-advisor-fixtures](https://github.com/appsec-foundry/appsec-advisor-fixtures) — test fixtures for `appsec-advisor`

## Reference 

- [github.com/appsec-foundry/appsec-advisor](https://github.com/appsec-foundry/appsec-advisor) — upstream plugin
- [docs/internal-plugin-packaging.md](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md) — full packaging runbook
- [docs/org-profiles.md](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md) — org-profile.yaml reference
