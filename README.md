# appsec-advisor — Org Packaging Template

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE) [![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-5A67D8.svg)](https://docs.claude.com/en/docs/claude-code) [![codecov](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template/graph/badge.svg)](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template) [![Upstream](https://img.shields.io/badge/upstream-appsec--advisor-orange.svg)](https://github.com/appsec-foundry/appsec-advisor)

This template creates an internal Claude Code plugin from [`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor) and your organization's configuration. The generated repository contains the profile, package policy, baseline, build scripts, and CI templates. The upstream plugin is fetched when the package is built.

## Quick start

The initializer is the recommended way to create a packaging repository. It collects the main settings, creates an initial Git commit, and offers to build the plugin immediately.

You need Git, curl, `sha256sum` (or `shasum` on macOS), Python 3.10+, Make, and Bash 3.2+ on macOS, Linux, or WSL. A local build also needs `PyYAML` and `jsonschema`; the initializer checks for them before it starts the build.

### 1. Create the packaging repository

Run the complete block below. It downloads the initializer from an exact Git commit and verifies the downloaded file before executing it.

```bash
curl --proto '=https' \
  --fail --silent --show-error \
  --output appsec-advisor-init.sh \
  https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/543d4105e7688832d1ec04c55db1ca0be8ef4495/scripts/init-org-repo.sh &&
echo '678b8411a1aab52704b9e2b2b7640242cf0042c51af774bfbfda22fd430b8d46  appsec-advisor-init.sh' |
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check
  else
    shasum -a 256 --check
  fi &&
bash appsec-advisor-init.sh
```

The initializer creates and commits a local repository. The prompt `Build the plugin now? [Y/n]` defaults to yes and writes the first package to `build/<plugin-name>/`. It does not push the repository, install the plugin, or create release archives.

To reuse organization defaults later, add `--save-defaults` to the final command. The saved values contain organization metadata and repository URLs, not credentials.

```bash
bash appsec-advisor-init.sh --save-defaults
```

### 2. Configure the organization

Change into the generated repository and review its organization-owned files. The initializer has already filled in the organization name, owner, plugin name, upstream channel, package version, and baseline source.

Start with these files:

- `org-profile/org-profile.yaml` contains presets, requirements, policy, branding, runtime toggles, hooks, and MCP servers.
- `org-profile/context/organization.md` must be replaced with short, factual organization context.
- `org-profile/package-policy.yaml` decides which skills, hooks, and MCP servers are included.
- `Makefile` contains `PACKAGE_VERSION`, the upstream ref, plugin name, and the internal repository URL shown in packaged help.

If requirements checks are used, set `requirements.source.requirements_yaml_url` to the approved catalog. Otherwise, remove that source from the profile.

### 3. Build and test locally

The initializer can create an initial package before you customize the repository. Run `make package` again after changing the profile, context, policy, hooks, or skills so the local package contains those changes.

```bash
make package

cd /path/to/a/test-project
claude --plugin-dir /absolute/path/to/packaging-repo/build/your-plugin-name
```

`make package` fetches the configured `appsec-advisor` ref, combines it with the organization files, validates the result, and smoke-tests the plugin under `build/<plugin-name>/`. It does not create an archive or install the plugin.

Once Claude Code starts, use the generated plugin name to check the local setup and run a representative analysis:

```text
/your-plugin-name:check-permissions --update
/your-plugin-name:create-threat-model
```

Use `make rebuild` when generated output may be stale. To test installation through a disposable local Marketplace instead of `--plugin-dir`, run `make install-local`; it does not change a shared Marketplace.

### 4. Add CI and publish a release

Install the CI file for the platform in use, then commit the generated file. These commands only copy the supplied template into its platform-specific location.

```bash
make ci-github
# or
make ci-gitlab
```

Before a release, set `PACKAGE_VERSION` in the `Makefile`, commit the change, and push `main`. Then create the matching release tag from a clean local `main` that exactly matches `origin/main`:

```bash
make release RELEASE_VERSION=1.2.0
```

The command runs the release checks, creates `v1.2.0`, and pushes that tag. CI then rebuilds the plugin and publishes ZIP, TGZ, and SHA-256 checksum files.

The two supplied CI definitions use different triggers. This table shows when they build and when they publish:

| Platform | Build | Scheduled check | Release |
|---|---|---|---|
| GitHub Actions | Manual run or `v*` tag | Included weekly; checks core and baseline drift | A `v*` tag creates a GitHub Release after x86-64 and ARM64 packaging pass |
| GitLab CI | Every non-scheduled pipeline | Configure a GitLab Pipeline Schedule | A `v*` tag creates a GitLab Release through the Generic Package Registry |

Shell lint is initially non-blocking in both templates. GitHub does not run the packaging workflow for normal branch pushes or pull requests. Build artifacts are retained for 30 days.

## Distribution options

Choose one distribution path and document it for developers. A released ZIP is the simplest option when the organization has no shared Claude Code Marketplace.

### Release or HTTPS server

Publish the versioned ZIP and its checksum through an approved HTTPS location. Developers can load the ZIP directly for one session:

```bash
claude --plugin-url \
  "https://plugins.corp.example/acme-appsec-1.2.0.zip"
```

The URL must return the ZIP itself. If it requires interactive authentication, download the archive first and use `claude --plugin-dir /path/to/plugin.zip`. Do not put credentials in the URL.

Use versioned URLs for controlled rollout and rollback. A moving URL such as `acme-appsec.zip` may point to the currently approved version, but the versioned archives and checksums should remain available.

### Local checkout

For a pilot, developers can clone the packaging repository, run `make package`, and load `build/<plugin-name>/` with `claude --plugin-dir`. Updating requires a new `git pull --ff-only` and build.

### Internal Marketplace

For a managed installation, add the released plugin to the organization's Claude Code Marketplace. Developers then register that Marketplace and install the plugin by name:

```bash
claude plugin marketplace add <marketplace-git-url>
claude plugin install <plugin-name>@<marketplace-name>
```

`make local-marketplace` and `make install-local` create only a local test Marketplace. They do not publish to the shared one.

## Organization-owned configuration

The following paths are the supported customization points. Generated files under `upstream/`, `build/`, and `dist/` must not be edited or committed.

| Path | Purpose |
|---|---|
| `Makefile` | Package version, upstream source, plugin name, and internal information URL |
| `org-profile/org-profile.yaml` | Identity, presets, requirements, policy, baseline, context, runtime toggles, hooks, and MCP servers |
| `org-profile/context/organization.md` | Organization context supplied to analyses as untrusted reference data |
| `org-profile/actors/*.yaml` | Organization-specific threat actors |
| `org-profile/baselines/*.md` | Reviewed secure-coding baseline shipped in the package |
| `org-profile/package-policy.yaml` | Allowlist for packaged skills, hooks, and MCP servers |
| `org-profile/hooks/*.py` | Organization-owned Claude Code event hooks |
| `org-skills/<skill-id>/SKILL.md` | Organization-owned skills packaged alongside upstream skills |

The package policy controls what is shipped. `skill_toggles` in the profile can disable a shipped skill at runtime with a visible reason. Add every organization-owned skill, hook, and MCP server to the corresponding allowlist, and do not reuse an upstream skill name.

Declare MCP servers only in the profile's `mcp:` block. Reference secrets with `${ENV_VAR}` and never place credentials in a server URL.

## Secure-coding baseline

The initializer supports four baseline modes: generic AISCB, an organization-owned Git source, one organization-owned HTTPS document, or no baseline. In every enabled mode, the reviewed document is stored in the packaging repository and shipped with the plugin. `make package` never updates it implicitly from its source.

The organization Git mode can also copy organization-owned skills. Those skills still need an explicit entry in `org-profile/package-policy.yaml` before they are shipped. Source configuration, synchronization, IDs, and overlays are documented in `org-profile/baselines/README.md` and the generated maintainer runbook.

## Keeping the package current

The upstream core, this packaging template, and the baseline are independent. Updating one does not update the others. The following table maps each source to its read-only check and update command:

| Source | Check | Update |
|---|---|---|
| `appsec-advisor` core | `make upstream-check` | Change the pinned ref for a Stable update, or rebuild a moving branch with `make upstream-update` |
| Packaging template | `make packaging-template-check` | `make reinit APPSEC_ADVISOR_TEMPLATE_REF=<reviewed-commit>` |
| Secure-coding baseline | `make baseline-sync-check` | `make baseline-sync`, with `ACCEPT_ID=<id>` when the ID changes |

### Update the appsec-advisor core

A generated Stable repository pins a concrete release tag. First check which release is available:

```bash
make upstream-check
```

Review that release, then update `APPSEC_ADVISOR_REF` and `PACKAGE_VERSION` in the `Makefile`. Build the selected version and test it locally:

```bash
make package
```

After the local test passes, commit the version changes and publish the release through the normal `make release RELEASE_VERSION=<version>` flow.

A repository configured for the `dev` branch fetches its current head on every build. `make upstream-update` rebuilds when that branch moved. It does not select a newer Stable release, change `PACKAGE_VERSION`, or publish anything.

### Update the packaging template

The initializer records the exact template commit used for the generated repository. Check for a newer commit, review it, and apply that exact revision:

```bash
make packaging-template-check
REINIT_BUILD=0 make reinit APPSEC_ADVISOR_TEMPLATE_REF=<reviewed-commit>
```

`REINIT_BUILD=0` leaves the package unbuilt while the migration is reviewed. Reinitialization preserves organization settings, asks before replacing changed user-owned files, stores replaced files under `.reinit-backups/`, and leaves all changes uncommitted. Review the diff, run `make package`, then commit.

### Update the baseline

Check the configured baseline source before writing its reviewed copy:

```bash
make baseline-sync-check
make baseline-sync
```

If the source declares a new baseline ID, the sync stops until that exact ID is accepted explicitly:

```bash
ACCEPT_ID=<new-id> make baseline-sync
```

`make check-updates` checks the core and baseline together. It does not check the packaging template.

## Common commands

These are the commands normally used after the repository has been generated. Run `make help` to see the current settings and the complete target list.

| Command | Purpose |
|---|---|
| `make check` | Run the offline lint and test gate |
| `make validate` | Validate the organization profile against the selected core |
| `make package` | Build and smoke-test the plugin under `build/` |
| `make rebuild` | Remove generated output and build again |
| `make release-check` | Run the release gate without creating a tag |
| `make release-package` | Create ZIP, TGZ, and checksum files under `dist/` |
| `make install-local` | Build and install through a disposable local Marketplace |

## Documentation

The initializer renders an organization-specific README and maintainer runbook into every generated repository. These template documents contain the detailed configuration and operating procedures:

- [Maintainer runbook template](docs/MAINTAINER-RUNBOOK.example.md)
- [Development guide](docs/DEVELOPMENT.md)
- [Organization profile reference](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
- [Internal plugin packaging](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)
- [appsec-advisor fixtures](https://github.com/appsec-foundry/appsec-advisor-fixtures)
