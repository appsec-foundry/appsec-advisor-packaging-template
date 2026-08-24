# acme-appsec

`acme-appsec` is the Claude Code security plugin maintained for Acme Corp by
the Acme AppSec Team. It adds our threat-modeling defaults, security
requirements, review guardrails, and organization context to the upstream
[appsec-advisor](https://github.com/appsec-foundry/appsec-advisor) plugin.

Use it when designing a new service, reviewing a significant change, preparing
a release, or checking whether an existing threat model still matches the
code. The plugin analyzes the repository in which Claude Code is running; it
does not replace the normal engineering or AppSec review process.

## What the plugin provides

- Threat models that can be created once and updated as the code changes.
- A session-start banner showing plugin, threat-model, and baseline status.
- Review and triage workflows for findings, accepted risks, and remediation.
- Checks against the application-security requirements maintained for Acme Corp.
- YAML and SARIF output for normal runs, with additional release-review output
  when the `release-review` preset is selected.
- Cost, duration, and quality limits maintained by the Acme AppSec Team.

## Getting started

If `acme-appsec` is already installed through our internal Claude Code
Marketplace, start Claude Code in the project you want to review. For a local
build, point Claude Code at the absolute plugin path:

```bash
cd /path/to/your/project
claude --plugin-dir /absolute/path/to/the-packaging-repo/build/acme-appsec
```

On first use in a repository, check the required permissions and create the
initial threat model:

```text
/acme-appsec:check-permissions --update
/acme-appsec:create-threat-model
```

The analysis can take several minutes depending on repository size and the
selected preset. Review the generated findings before using them in a release
or risk decision.

## Skills and commands

| Command | When to use it |
|---|---|
| `/acme-appsec:help` | Show the commands included in this organization package and whether any are disabled |
| `/acme-appsec:create-threat-model` | Create the first threat model for a repository |
| `/acme-appsec:update-threat-model` | Re-analyze relevant changes without starting over |
| `/acme-appsec:review-threat-model` | Triage findings and plan remediation |
| `/acme-appsec:ask-threat-model` | Ask read-only questions about the current model |
| `/acme-appsec:show-threat-model` | Show the current findings, backlog, and coverage summary |
| `/acme-appsec:threat-model-health` | Check whether the model is stale or incomplete |
| `/acme-appsec:audit-security-requirements` | Audit the repository against our requirements catalog |
| `/acme-appsec:verify-requirements` | Check recent changes against applicable requirements |
| `/acme-appsec:status` | Show the current run state |
| `/acme-appsec:fix-run-issues` | Diagnose and repair a failed or interrupted run |
| `/acme-appsec:clean-run-state` | Remove stale run state before a clean restart |

The two requirements commands are available only after the requirements
catalog has been configured and enabled by the Acme AppSec Team. If a command
is disabled, Claude Code shows the reason rather than running it.

The `/acme-appsec:help` reference is generated during packaging from the final
allowlist and runtime toggles. It therefore lists the package people actually
have, including organization-owned skills, instead of the larger upstream
command set. Its “More information” link comes from `banner.url` in
`org-profile/org-profile.yaml`.

## Headless and CI use

For CI or a scripted review, use the wrapper included in the built plugin:

```bash
/absolute/path/to/the-packaging-repo/build/acme-appsec/scripts/run-headless.sh \
  --repo /path/to/your/project \
  --incremental \
  --max-duration 1800 \
  --max-budget 5 \
  --sarif
```

The wrapper supplies the plugin path and command namespace and applies the
requested cost, duration, output, and exit-code settings. See the upstream
[headless-mode guide](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/headless-mode.md)
for the full flag reference.

## Getting help

Before reporting a problem:

1. Run `/acme-appsec:status` to inspect the current state.
2. Run `/acme-appsec:fix-run-issues` for a failed or interrupted analysis.
3. Include the command used, the selected preset, and the non-sensitive part of
   the error when contacting the Acme AppSec Team.

Do not attach source code, credentials, tokens, or complete analysis artifacts
to tickets unless the support channel is approved for that data.

## For AppSec maintainers

The setup script normally creates the first package. Rebuild after changing the
profile, package policy, hooks, or organization skills:

```bash
make package
```

To update this repository from the current packaging template, run `make
reinit`. Infrastructure is refreshed automatically. When a user-editable
template file differs, choose whether to overwrite or keep it individually, or
apply that choice to all remaining files. The default is to keep it; every
overwritten file is backed up under `.reinit-backups/`. Existing organization
and plugin identity settings are reused, and all changes remain uncommitted for
review. The plugin is rebuilt afterwards; use `REINIT_BUILD=0 make reinit` to
skip that build. For legacy repositories, reinitialization also ensures the
package policy enables `help` and, when the session banner is enabled, its
`session-banner` hook.

### Customize skills

Add an organization-owned skill under `org-skills/<skill-id>/SKILL.md` and
include its id in `org-profile/package-policy.yaml`. The same policy controls
which bundled skills are present in the package: use its `include` or `exclude`
selection to remove a command entirely. To keep a command installed but block
it at runtime with an explanation, configure `skill_toggles` in
`org-profile/org-profile.yaml` instead.

See the upstream [internal packaging guide](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)
and [organization profile reference](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
for the full configuration syntax.

The plugin is written to `build/acme-appsec/` and smoke-tested as part of the
build. `PACKAGE_VERSION` in the `Makefile` is the internal release number shown
in the session banner and packaged help; it is intentionally independent of the
upstream version selected by `APPSEC_ADVISOR_REF`. The package retains that
upstream core version separately for compatibility checks. Before publishing a
release, run:

```bash
make release-check
```

Configuration owned by the Acme AppSec Team:

| Path | Purpose |
|---|---|
| `Makefile` → `PACKAGE_VERSION` | Internal plugin release shown in the banner, help and package filename |
| `org-profile/org-profile.yaml` | Presets, requirements, guardrails, organization hooks, and optional MCP servers |
| `org-profile/context/organization.md` | Organization context supplied to analyses as untrusted reference data |
| `org-profile/actors/*.yaml` | Threat actors specific to Acme Corp |
| `org-profile/hooks/*.py` | Organization-owned Claude Code event hooks |
| `org-profile/package-policy.yaml` | Allowlist for packaged skills, hooks, and MCP servers |
| `org-skills/<skill-id>/SKILL.md` | Skills maintained by the Acme AppSec Team |

`org-profile/package-policy.yaml` is an allowlist. A new skill, hook, or MCP
server is not shipped until its id is included there. Keep credentials and
tokens out of this repository; MCP configuration must reference them through
`${ENV_VAR}` values.

Install a CI definition with `make ci-github` or `make ci-gitlab`. Generated
content under `upstream/`, `build/`, and `dist/` must not be committed.

Maintainer references:

- [Organization profiles](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
- [Internal plugin packaging](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)

## Repository lineage

This internal packaging repository was generated with the
[appsec-advisor packaging template](https://github.com/appsec-foundry/appsec-advisor-packaging-template)
and builds an organization-specific distribution of
[appsec-advisor](https://github.com/appsec-foundry/appsec-advisor). The source
URLs and pinned refs used by the repository are recorded in the `Makefile`.
