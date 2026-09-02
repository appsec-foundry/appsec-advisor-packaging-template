# acme-appsec packaging

This repository builds and releases the `acme-appsec` Claude Code security plugin maintained for Acme Corp by the Acme AppSec Team. It combines the upstream [`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor) plugin with our organization profile, secure-coding baseline, package policy, context, hooks, and organization-owned skills. The baseline is the versioned set of security rules the plugin installs for Claude Code to follow while writing or changing code; the package policy is the allowlist of features shipped to developers.

<!-- INTERNAL_REPOSITORY_LINK -->

AppSec and platform maintainers own this repository. Developers normally consume a released ZIP or install the plugin from the internal Marketplace; they do not need the packaging toolchain or its Python build dependencies.

## Maintainer quick start

The initializer has already set the organization identity, package name, version, owner, upstream channel, baseline source, and startup-status choice. The default stable channel is resolved to a concrete release tag; the optional development channel follows the upstream `dev` branch. Review the remaining organization-specific content before rollout:

- Replace `org-profile/context/organization.md` with factual organization context.
- Configure requirements, presets, policy, banner, baseline, and guardrails in `org-profile/org-profile.yaml` as needed.
- Run `make baseline-sync-check` to verify the configured [AISCB](https://github.com/appsec-foundry/aiscb), organization Git, or organization HTTPS source. Use `make baseline-sync` after reviewing source changes; a new ID requires `ACCEPT_ID=<id>`.
- Add organization skills under `org-skills/`, and include or remove skills, hooks, and MCP servers through `org-profile/package-policy.yaml`.

A preset bundles an analysis depth, its outputs, and guardrails. Requirements are organization controls that the optional audit commands evaluate. Skills are plugin workflows exposed as slash commands.

To disable a hook, remove its id from `plugin_surface.hooks.include`. To add or replace behavior, declare an organization hook under a distinct `org-...` id and include that id. Reusing an upstream hook id fails validation.

MCP endpoints are declared under `mcp.servers` in `org-profile.yaml` and become part of `.mcp.json` only when their ids are present in `plugin_surface.mcp_servers.include`. Removing an id from that allowlist removes the endpoint from the built plugin. Keep credentials in `${ENV_VAR}` references. The maintainer runbook contains complete examples for both customizations.

The initializer offered to create an initial package. Build again after changing the organization files, then load that result from a representative project:

```bash
make package

cd /path/to/a/test-project
claude --plugin-dir /absolute/path/to/acme-appsec-packaging/build/acme-appsec
```

`make package` fetches the configured upstream ref, applies the organization configuration, validates the result, and smoke-tests it under `build/`. It does not install the plugin or create release archives. Do not edit generated `config.json`, `.claude-plugin/package-surface.json`, packaged help, or packaged README files in place.

For the full operating procedure, see [`docs/MAINTAINER-RUNBOOK.md`](docs/MAINTAINER-RUNBOOK.md).

## Publish for developers

### Tagged CI release

Install one of the supplied CI definitions once and commit the resulting file:

```bash
make ci-github
# or
make ci-gitlab
```

For each release, update `PACKAGE_VERSION` in the `Makefile`, commit and push that change, then create the matching tag from a clean, synchronized `main`:

```bash
make release RELEASE_VERSION=0.1.0
```

The release command runs the release checks and pushes `v0.1.0`. CI rebuilds the plugin and publishes ZIP, TGZ, and SHA-256 checksum files.

### Manual archive hosting

To build release files without creating or pushing a tag, run:

```bash
make release-package
```

This creates distributable archives under `dist/` but does not upload them. Upload the ZIP and checksum to the approved internal HTTPS location. Developers load the direct ZIP URL with `claude --plugin-url`.

### Internal Marketplace

The organization may instead publish the released plugin through its central Claude Code Marketplace. `make local-marketplace` and `make install-local` are only for local Marketplace testing; they do not update the shared Marketplace.

## Developer quick start

Use the distribution method approved by the Acme AppSec Team.

From a release URL:

```bash
cd /path/to/your/project
claude --plugin-url "<direct ZIP URL from the release>"
```

The URL must return the ZIP itself. If it requires interactive authentication, download the ZIP and use `claude --plugin-dir /path/to/acme-appsec.zip`. Never put credentials or access tokens in a plugin URL.

From an internal Marketplace:

```bash
claude plugin marketplace add <marketplace-git-url>
claude plugin install acme-appsec@<marketplace-name>
```

After the plugin loads, start with:

```text
/acme-appsec:help
/acme-appsec:install-baseline
/acme-appsec:check-permissions --update
/acme-appsec:create-threat-model
```

`install-baseline` installs the reviewed secure-coding rules shipped with the plugin, whether they come from [AISCB](https://github.com/appsec-foundry/aiscb) or an organization source. The status line at the start of a session says whether those rules are loaded.

Nothing updates the installed rules automatically. A package with a configured refresh URL can update them through `/acme-appsec:install-baseline --refresh`. Organization-owned source modes distribute baseline changes through a new plugin package instead.

The packaged README and `/acme-appsec:help` are generated from the actual package surface. They show the exact commands included by the Acme AppSec Team and mark commands that are currently disabled.

## Support

For a failed or interrupted run, use `/acme-appsec:status` and `/acme-appsec:fix-run-issues` when those commands are available. When escalating, include the command, selected preset, and non-sensitive part of the error.

Do not send credentials, tokens, source code, or complete analysis artifacts through a support channel that is not approved for that data.

## Documentation

- [Maintainer runbook](docs/MAINTAINER-RUNBOOK.md) — configuration, build, CI, releases, Marketplace rollout, updates, and troubleshooting
- Packaged `README.md` — developer guidance for the exact built package
- `/acme-appsec:help` — authoritative command and package-policy reference
- [Upstream organization profiles](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
- [Upstream internal packaging](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)

## Repository lineage

This repository was generated with the [`appsec-advisor` packaging template](https://github.com/appsec-foundry/appsec-advisor-packaging-template). The upstream source URL and selected release tag or branch ref are recorded in the `Makefile`. The exact manual Stable and Development update procedures are in [`docs/MAINTAINER-RUNBOOK.md`](docs/MAINTAINER-RUNBOOK.md#versioning-and-upstream-updates).
