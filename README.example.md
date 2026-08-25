# acme-appsec packaging

This repository builds and releases the `acme-appsec` Claude Code security
plugin maintained for Acme Corp by the Acme AppSec Team. It combines the
upstream [`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor)
plugin with our organization profile, secure-coding baseline, package policy,
context, hooks, and organization-owned skills.

<!-- INTERNAL_REPOSITORY_LINK -->

AppSec and platform maintainers own this repository. Developers normally consume
a released ZIP or install the plugin from the internal Marketplace; they do not
need the packaging toolchain or its Python build dependencies.

## Maintainer quick start

The initializer has already set the organization identity, package name,
version, owner, upstream channel, baseline choice, and startup-status choice.
The default stable channel is resolved to a concrete release tag; the optional
development channel follows the upstream `dev` branch. Review the remaining
organization-specific content before rollout:

- Replace `org-profile/context/organization.md` with factual organization
  context.
- Configure requirements, presets, policy, banner, baseline, and guardrails in
  `org-profile/org-profile.yaml` as needed.
- Add organization skills under `org-skills/`, and include or remove skills,
  hooks, and MCP servers through `org-profile/package-policy.yaml`.

Build and test the local package:

```bash
make package

cd /path/to/a/test-project
claude --plugin-dir /absolute/path/to/acme-appsec-packaging/build/acme-appsec
```

The build writes generated output under `build/`. Do not edit generated
`config.json`, `.claude-plugin/package-surface.json`, packaged help, or packaged
README files in place.

For the full operating procedure, see
[`docs/MAINTAINER-RUNBOOK.md`](docs/MAINTAINER-RUNBOOK.md).

## Publish for developers

### Tagged CI release

After installing and committing one of the supplied CI definitions, publish a
version from a clean, synchronized `main` branch:

```bash
make ci-github  # or: make ci-gitlab
make release RELEASE_VERSION=1.0.0
```

The release command runs the release checks and pushes `v1.0.0`. CI rebuilds the
plugin and publishes ZIP, TGZ, and SHA-256 checksum files.

### Manual archive hosting

```bash
make release-package
```

This creates distributable archives under `dist/` but does not upload them.
Upload the ZIP and checksum to the approved internal HTTPS location. Developers
load the direct ZIP URL with `claude --plugin-url`.

### Internal Marketplace

The organization may instead publish the released plugin through its central
Claude Code Marketplace. `make local-marketplace` and `make install-local` are
only for local Marketplace testing; they do not update the shared Marketplace.

## Developer quick start

Use the distribution method approved by the Acme AppSec Team.

From a release URL:

```bash
cd /path/to/your/project
claude --plugin-url "<direct ZIP URL from the release>"
```

The URL must return the ZIP itself. If it requires interactive authentication,
download the ZIP and use `claude --plugin-dir /path/to/acme-appsec.zip`. Never
put credentials or access tokens in a plugin URL.

From an internal Marketplace:

```bash
claude plugin marketplace add <marketplace-git-url>
claude plugin install acme-appsec@<marketplace-name>
```

After the plugin loads, start with:

```text
/acme-appsec:help
/acme-appsec:check-permissions --update
/acme-appsec:create-threat-model
```

The packaged README and `/acme-appsec:help` are generated from the actual
package surface. They show the exact commands included by the Acme AppSec Team
and mark commands that are currently disabled.

## Support

For a failed or interrupted run, use `/acme-appsec:status` and
`/acme-appsec:fix-run-issues` when those commands are available. When escalating,
include the command, selected preset, and non-sensitive part of the error.

Do not send credentials, tokens, source code, or complete analysis artifacts
through a support channel that is not approved for that data.

## Documentation

- [Maintainer runbook](docs/MAINTAINER-RUNBOOK.md) — configuration, build, CI,
  releases, Marketplace rollout, updates, and troubleshooting
- Packaged `README.md` — developer guidance for the exact built package
- `/acme-appsec:help` — authoritative command and package-policy reference
- [Upstream organization profiles](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
- [Upstream internal packaging](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)

## Repository lineage

This repository was generated with the
[`appsec-advisor` packaging template](https://github.com/appsec-foundry/appsec-advisor-packaging-template).
The upstream source URL and selected release tag or branch ref are recorded in
the `Makefile`. The exact manual Stable and Development update procedures are in
[`docs/MAINTAINER-RUNBOOK.md`](docs/MAINTAINER-RUNBOOK.md#versioning-and-upstream-updates).
