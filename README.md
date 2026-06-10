# appsec-advisor — Org Packaging Template

Template repo for building an internal [`appsec-advisor`](https://github.com/matthiasrohr/appsec-advisor) Claude Code plugin with your own org-specific defaults, requirements catalog, and cost guardrails.

## Quick Start

**Prerequisites:** `git`, `python3` (3.10+), `make`

**1. Create your packaging repo**

Run the init script — it asks for your org name and plugin name, then creates a ready-to-use git repo with all placeholders already replaced:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/matthiasrohr/appsec-advisor-org-packaging-template/main/scripts/init-org-repo.sh)
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

That's it. For CI, tagging a release triggers the pipeline set up in step 3 automatically.

## Customization

Beyond the quick start, these files are yours to edit:

| File | Purpose |
|---|---|
| `org-profile/org-profile.yaml` | Presets, cost guardrails, requirements source, output formats |
| `org-profile/context/organization.md` | Short org context injected into analyses (max 50 KB) |
| `org-profile/actors/*.yaml` | Custom threat actors for threat models — edit or delete |
| `org-profile/package-policy.yaml` | Allowlist of which upstream skills and hooks to include |

`build/`, `dist/`, and `upstream/` are all generated — do not commit them.

## Build Reference

```bash
# Validate org profile only
make validate

# Fetch upstream + build + smoke test
make package

# Force a clean rebuild (removes upstream/, build/, dist/ first)
make rebuild

# Remove all generated directories
make clean

# Pin a specific upstream release
APPSEC_ADVISOR_REF=v0.4.0-beta make package

# Build a distributable archive (.tgz + .sha256)
ARCHIVE=1 VERSION=1.0.0 make package-archive

# Use an existing local upstream checkout
APPSEC_ADVISOR_SOURCE=/path/to/local/appsec-advisor make package
```

## CI

Run `make ci-github` or `make ci-gitlab` to install the CI pipeline (see Quick Start step 3). Both do the same as the local build: fetch upstream, build, smoke test, and upload the `.tgz` with its `.sha256` as a build artifact. The pipeline triggers on `v*` tags and `workflow_dispatch`.

| Variable | Default | Description |
|---|---|---|
| `APPSEC_ADVISOR_URL` | upstream GitHub | Upstream repo or internal fork |
| `APPSEC_ADVISOR_REF` | `latest` | Release tag, branch, or commit — pin for reproducible builds |
| `INTERNAL_NAME` | `acme-appsec` | Plugin name and Claude Code command namespace |
| `VERSION` | derived from git tag or commit SHA | Version of the produced package |

## Reference

- [github.com/matthiasrohr/appsec-advisor](https://github.com/matthiasrohr/appsec-advisor) — upstream plugin
- [docs/internal-plugin-packaging.md](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/internal-plugin-packaging.md) — full packaging runbook
- [docs/org-profiles.md](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/org-profiles.md) — org-profile.yaml reference
