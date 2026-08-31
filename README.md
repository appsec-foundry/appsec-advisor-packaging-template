# appsec-advisor — Org Packaging Template

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-5A67D8.svg)](https://docs.claude.com/en/docs/claude-code)
[![codecov](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template/graph/badge.svg)](https://codecov.io/gh/appsec-foundry/appsec-advisor-packaging-template)
[![Upstream](https://img.shields.io/badge/upstream-appsec--advisor-orange.svg)](https://github.com/appsec-foundry/appsec-advisor)

Template for building an internal [`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor) Claude Code plugin with organization-specific defaults, requirements, and guardrails.

## Quick start

**Prerequisites:** Git, curl, `sha256sum` (or `shasum` on macOS), Python 3.10+,
Make, and a Bash 3.2+ environment (macOS/Linux or WSL on Windows). Local builds
also require `PyYAML` and `jsonschema`. The initializer checks the required tools
before building.

### 1. Create your packaging repository

Copy and run the complete command block. It downloads the initializer from an
immutable commit, verifies it before execution, and then starts its prompts:

```bash
curl --proto '=https' \
  --fail --silent --show-error \
  --output appsec-advisor-init.sh \
  https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/ac717bf5f0d83a149d32202b1957ccec3c3b1f5f/scripts/init-org-repo.sh &&
echo 'a331c4d285793aa8977beb9bc21d2452e77e96717d0a4f4e6b1aeaf7c9e810c5  appsec-advisor-init.sh' |
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check
  else
    shasum -a 256 --check
  fi &&
bash appsec-advisor-init.sh
```

It creates and commits a local Git repository and can build the plugin. It does not push the repository or install the plugin.

Alternatively, click **Use this template** on GitHub and replace `Acme Corp` and `acme-appsec` manually.

### 2. Configure your organization

Edit `org-profile/org-profile.yaml`. When using the initializer, organization identity and ownership are already configured. Review the profile and either set `requirements.source.requirements_yaml_url` to your internal requirements catalog or remove that source.

Set `INTERNAL_REPOSITORY_URL` in the `Makefile` to the internal HTTPS repository or information page shown in packaged help. The initializer sets it when you provide a URL.

### 3. Build and test locally

```bash
make package
claude --plugin-dir build/your-plugin-name
```

Then run these commands in Claude Code:

```text
/your-plugin-name:check-permissions --update
/your-plugin-name:create-threat-model
```

The build fetches the pinned upstream plugin, applies your configuration, generates help and a developer README, smoke-tests the package, and writes it under `build/`. Use `make rebuild` for a clean rebuild.

### 4. Add CI and publish

Install the CI definition for your platform and commit the generated file:

```bash
make ci-github
# or
make ci-gitlab
```

After pushing `main`, create a release:

```bash
make release RELEASE_VERSION=0.1.0
```

The release command checks the build, creates the `v0.1.0` tag, and pushes it. The supplied CI publishes versioned archives and checksums for the tag. GitLab releases require the project's Generic Package Registry.

## Distribution options

### Release or HTTPS server

This is the simplest option when there is no internal Marketplace. Developers can load a published ZIP directly:

```bash
claude --plugin-url \
  "https://plugins.corp.example/acme-appsec.zip"
```

This short URL is a moving alias for the currently approved release; retain the versioned archives and checksums for auditing and rollback. The URL must return the ZIP itself. If it requires interactive authentication, download the archive first and use `claude --plugin-dir /path/to/plugin.zip`. Never put credentials in the URL.

### Local checkout

For pilots, developers can clone this repository, run `make package`, and load the resulting directory with `claude --plugin-dir`. Updating requires `git pull --ff-only` followed by another build.

### Internal Marketplace

For persistent managed installation, publish the released plugin through your organization's Claude Code Marketplace:

```bash
claude plugin marketplace add <marketplace-git-url>
claude plugin install <plugin-name>@<marketplace-name>
```

`make local-marketplace` and `make install-local` create only a disposable local Marketplace for testing; they do not update a shared Marketplace.

## Organization-owned configuration

| Path | Purpose |
|---|---|
| `Makefile` | Package version, upstream source, plugin name, and internal information URL |
| `org-profile/org-profile.yaml` | Identity, presets, requirements, policy, baseline, context, runtime toggles, hooks, and MCP servers |
| `org-profile/context/organization.md` | Organization context supplied to analyses as untrusted reference data |
| `org-profile/actors/*.yaml` | Organization-specific threat actors |
| `org-profile/package-policy.yaml` | Allowlist for packaged skills, hooks, and MCP servers |
| `org-profile/hooks/*.py` | Organization-owned Claude Code event hooks |
| `org-skills/<skill-id>/SKILL.md` | Organization-owned skills packaged alongside upstream skills |

`org-profile/package-policy.yaml` controls what is included in the package. Its top-level `optional_skills:` list holds ids that a selected upstream ref may not have yet, so an unreleased upstream skill can be allowlisted without breaking builds from the pinned release. `skill_toggles` in `org-profile/org-profile.yaml` controls whether an included skill is available at runtime. Add every organization-owned skill, hook, and MCP server to the package allowlist, and do not reuse an upstream skill name.

Declare MCP servers only in the profile's `mcp:` block. Reference secrets with `${ENV_VAR}`; never commit tokens or put credentials in server URLs.

`upstream/`, `build/`, and `dist/` are generated and must not be committed. Generated `config.json`, package-surface metadata, help, and packaged READMEs must be changed through the profile or package policy rather than edited in place.

## Common commands

| Command | Purpose |
|---|---|
| `make help` | List the targets by topic and the current build settings |
| `make check` | Run the offline lint and test gate |
| `make validate` | Validate the organization profile |
| `make package` | Build and smoke-test the plugin |
| `make rebuild` | Remove generated output and rebuild |
| `make release-check` | Run the release gate and package build |
| `make release-package` | Create ZIP/TGZ archives and checksums under `dist/` |
| `make upstream-check` | Check whether the selected upstream source moved |
| `make upstream-update` | Rebuild, but only when the selected upstream ref moved to a new commit |
| `make packaging-template-check` | Check whether the packaging template has moved |
| `make baseline-check` | Compare the configured baseline with its published document |
| `make check-updates` | Check appsec-advisor and baseline updates |
| `make reinit` | Reapply the pinned template while preserving organization settings |

`PACKAGE_VERSION` is the organization-owned plugin version; `APPSEC_ADVISOR_REF` independently selects the upstream implementation. Both default in the `Makefile` and can be overridden for a build.

The initializer records the exact packaging-template commit in generated
repositories. Run `make packaging-template-check` to check for a newer revision. After
reviewing the available change, update deliberately with
`make reinit APPSEC_ADVISOR_TEMPLATE_REF=<reported-commit>`; using the exact
reported commit avoids a moving-branch race. Organization settings are retained,
and changes remain uncommitted for review.

## Documentation

- [Maintainer runbook template](docs/MAINTAINER-RUNBOOK.example.md) — complete configuration, CI, release, update, and troubleshooting procedures
- [Development guide](docs/DEVELOPMENT.md) — workflow for changing this template
- [Organization profile reference](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
- [Internal plugin packaging](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)
- [appsec-advisor fixtures](https://github.com/appsec-foundry/appsec-advisor-fixtures)
