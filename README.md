# appsec-advisor — Org Packaging Template

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-5A67D8.svg)](https://docs.claude.com/en/docs/claude-code)
[![codecov](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template/graph/badge.svg)](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template)
[![Upstream](https://img.shields.io/badge/upstream-appsec--advisor-orange.svg)](https://github.com/appsec-foundry/appsec-advisor)

Template repo for building an internal [`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor) Claude Code plugin with your own org-specific defaults, requirements catalog, and cost guardrails.

See [the developer documentation](docs/DEVELOPMENT.md) for the development
workflow.

## Quick Start

**Prerequisites:** Bash 3.2+, `git`, `python3` (3.10+), `make`, `sed`, and
`mktemp`. A local plugin build also needs the Python modules `PyYAML` and
`jsonschema`; the initializer checks these before starting the optional build
and CI installs its reviewed versions from `ci-requirements.lock`.

**1. Create your packaging repo**

Run the init script — it asks for your org name and plugin name, creates a
package version, configures optional startup status and an internal information
URL, creates a ready-to-use git repo, and offers to build the plugin immediately.
The generated profile explicitly pins `aisec-0.1.7`, the currently published
baseline from
[`appsec-foundry/ai-secure-coding-baseline`](https://github.com/appsec-foundry/ai-secure-coding-baseline)
instead of the older baseline bundled with the pinned plugin core. A later
published version is reported by `make baseline-check`.

The script checks its prerequisites before asking questions and explains how to
recover when a command, supported Python version, Git author identity, or local
Python build module is missing. It creates only a local repository and commit;
it does not push or install the plugin. Start it with:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
```

Alternatively, click **Use this template** on GitHub and replace `Acme Corp` / `acme-appsec` manually.

**2. Edit your org profile**

Open `org-profile/org-profile.yaml` in your new repo. If you used the init script, `organization.id`, `.name`, `.profile_version`, and `.owner` are already filled in. The one thing to update manually:

- Point `requirements.source.requirements_yaml_url` to your internal requirements catalog, or remove that block if you don't have one yet.

If you used the GitHub Template instead, also replace `organization.id`, `.name`, `.profile_version`, and `.owner` with your values.

`PACKAGE_VERSION` in the generated `Makefile` is used for local builds. It
defaults to `0.1.0` and is independent of `APPSEC_ADVISOR_REF`. Releases use
the version from their tag.

Set `INTERNAL_REPOSITORY_URL` to the HTTPS URL of the internal packaging
repository. The initializer fills it when provided and configures it as
`origin` when the new local repository has no remote yet. It also becomes the
“More information” link in packaged help and README output; an empty value
omits that link.

**3. Set up CI for your platform** — run one of:

```bash
make ci-github   # copies ci-templates/github/workflows/package.yml → .github/workflows/
make ci-gitlab   # copies ci-templates/gitlab-ci.yml → .gitlab-ci.yml
```

Then set `INTERNAL_NAME` to your plugin name in the CI repository variables if it differs from the default.
GitLab tag releases require the project's Package Registry to be enabled.

**4. Build the plugin locally:**

```bash
make package
```

This fetches the upstream plugin, overlays your org profile, generates `/help`
and the developer-facing README from the final package allowlist and runtime
configuration, runs a smoke test, and writes the result to
`build/your-plugin-name/`. Verified legacy GitHub links in
the pinned upstream release are normalized to their `appsec-foundry` origins;
the build stops if it encounters an unknown personal-repository link. The
original upstream help is not changed. To force a clean rebuild:

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

**7. Publish a release** after committing the CI definition and pushing
`main`:

```bash
make release RELEASE_VERSION=1.0.0
```

This checks the build, creates the `v1.0.0` tag, and pushes it. CI publishes
the archives and checksums as a GitLab or GitHub Release.

## Rollout options

### Release or web server

This is the recommended path when there is no internal Marketplace. A release
starts with:

```bash
make release RELEASE_VERSION=1.0.0
```

The command checks and tags `main`. The tag starts CI. `make package-archive`
then builds the archives for publication. The included definitions use GitLab
or GitHub Releases. The same ZIP can instead be uploaded to S3, Nexus,
Artifactory, or a normal HTTPS web server.

`make package-archive` creates both `.zip` and `.tgz` files under `dist/`. Use
the ZIP with `--plugin-url`; the TGZ is for conventional download workflows.

Developers load it without checking out the packaging repository:

```bash
claude --plugin-url \
  "https://plugins.example.com/acme-appsec/1.0.0/acme-appsec-1.0.0.zip"
```

Claude Code 2.1.129 or newer is required. The URL must return the ZIP directly,
not a release page. Claude Code loads it for the current session. Use a
versioned URL for a pinned rollout, or offer a second stable URL such as
`/latest/acme-appsec.zip` for the newest release.

If the URL requires an interactive login, download the ZIP from the release
page while signed in and use `claude --plugin-dir /path/to/plugin.zip`.
Credentials must not be embedded in the URL.

### Local checkout

For a pilot or local testing, each developer can build the plugin:

```bash
git clone <internal-packaging-repository> /path/to/appsec-packaging
cd /path/to/appsec-packaging
make package

cd /path/to/application
claude --plugin-dir /path/to/appsec-packaging/build/acme-appsec
```

Updates require `git pull --ff-only` followed by another `make package`.
`build/` remains generated and is not committed.

### Internal Marketplace

If the organization maintains a Claude Code Marketplace, developers add it and
install the plugin once:

```bash
claude plugin marketplace add <marketplace-git-url>
claude plugin install <plugin-name>@<marketplace-name>
```

This provides persistent installation and managed updates. The
`local-marketplace` target only creates a catalog for local testing; it is not
the organization's shared Marketplace.

## Customization

Beyond the quick start, these files are yours to edit:

| File | Purpose |
|---|---|
| `Makefile` → `PACKAGE_VERSION` | Organization-owned plugin version shown to users |
| `Makefile` → `INTERNAL_REPOSITORY_URL` | Internal packaging repository used as `origin` and shown in packaged help and README output |
| `org-profile/org-profile.yaml` | Identity, presets, requirements, policy, banner, baseline, context routing, security coach, actors, abuse cases, skill toggles, hooks, and MCP servers |
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

### Control which skills are available

`org-profile/package-policy.yaml` controls the build-time surface. A skill in
its `include` list is packaged; a skill removed by the policy does not exist in
the finished plugin. `skill_toggles` in `org-profile/org-profile.yaml` controls
the runtime state of skills that were packaged, including the reason shown when
a command is disabled.

The generated `config.json` contains the resolved runtime settings and points
maintainers back to the profile, its referenced files, and
`.claude-plugin/package-surface.json`, which records the final skills, hooks,
and MCP servers. Both files under `build/` are generated; make changes in the
profile and package policy, then rebuild. `/your-plugin-name:help` shows the
effective skill selection from the finished package.

### Control the startup status

The session-start status is controlled at two layers. `banner.enabled: false`
in `org-profile/org-profile.yaml` makes the runtime default silent. Removing
`session-banner` from `plugin_surface.hooks` in `package-policy.yaml` removes
the hook from the package entirely. The initializer keeps both settings aligned
when you decline startup status, and `make reinit` preserves a deliberate
package-level removal.

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

# Reapply the current main template using this repo's existing settings
make reinit

# Refresh infrastructure without rebuilding the plugin afterwards
REINIT_BUILD=0 make reinit

# Remove all generated directories
make clean

# Read-only drift check (newer release, or branch tip moved past local build)
make upstream-check

# Compare the configured baseline id with its published document
make baseline-check

# Check both upstream sources for available updates
make check-updates

# Pin a specific upstream release
APPSEC_ADVISOR_REF=v0.6.0-beta.1 make package

# Follow a different branch tip (re-pulled to its tip on each build)
APPSEC_ADVISOR_REF=main make package

# Build distributable .tgz and .zip archives with checksums
ARCHIVE=1 PACKAGE_VERSION=1.0.0 make package-archive

# Validate main, create v1.0.0 and trigger the configured CI release
make release RELEASE_VERSION=1.0.0

# Use an existing local upstream checkout
APPSEC_ADVISOR_SOURCE=/path/to/local/appsec-advisor make package

# Generate build/.claude-plugin/marketplace.json for local marketplace testing
make local-marketplace

# Register that generated marketplace and install the plugin locally
make install-local
```

During reinitialization, changed user-editable template files can be kept or
overwritten individually, with choices to apply either decision to all
remaining files. Overwritten files are backed up under `.reinit-backups/` and
the resulting changes are left uncommitted for review.

`install-local` uses the marketplace name `<plugin-name>-local` and Claude
Code's `local` installation scope. Override these with
`LOCAL_MARKETPLACE_NAME` and `LOCAL_MARKETPLACE_SCOPE` when needed. The
generated catalog lives under `build/`; it is only a local test adapter and
does not replace your organization's existing marketplace.

## CI

Run `make ci-github` or `make ci-gitlab` to install the CI pipeline (see Quick
Start step 3). Normal builds keep the archives for 30 days. A `v*` tag publishes
them as a GitHub Release or as a GitLab Release backed by the Generic Package
Registry. Create the tag with `make release RELEASE_VERSION=x.y.z`.

| Variable | Default | Description |
|---|---|---|
| `APPSEC_ADVISOR_URL` | upstream GitHub | Upstream repo or internal fork |
| `APPSEC_ADVISOR_REF` | `v0.6.0-beta.1` | Pinned upstream release; explicitly set it to override |
| `INTERNAL_NAME` | `acme-appsec` | Plugin name and Claude Code command namespace |
| `PACKAGE_VERSION` | `0.1.0` | Organization-owned version shown in the banner, help, manifest and archive name |
| `INTERNAL_REPOSITORY_URL` | empty | Internal HTTPS packaging repository; also shown to developers |
| `VERSION` | empty | Optional one-off override of `PACKAGE_VERSION` for non-tagged builds |

## Related Projects

- [appsec-advisor](https://github.com/appsec-foundry/appsec-advisor) — upstream Claude Code plugin this template packages
- [appsec-advisor-fixtures](https://github.com/appsec-foundry/appsec-advisor-fixtures) — test fixtures for `appsec-advisor`

## Reference 

- [github.com/appsec-foundry/appsec-advisor](https://github.com/appsec-foundry/appsec-advisor) — upstream plugin
- [docs/internal-plugin-packaging.md](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md) — full packaging runbook
- [docs/org-profiles.md](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md) — org-profile.yaml reference
