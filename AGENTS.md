# AGENTS.md

This repository is an **example**: it shows how an organization packages and
customizes the `appsec-advisor` Claude Code plugin for internal use. Treat it as
a template for your own internal packaging repository. It holds organization
configuration and build logic only — **no application code**. The plugin itself
lives upstream at `https://github.com/appsec-foundry/appsec-advisor.git` and is
cloned to `upstream/appsec-advisor` at build time.

## What you may change here

| File / directory | Purpose |
|---|---|
| `org-profile/org-profile.yaml` | The central knob — see [What you can customize](#what-you-can-customize). Full reference upstream: [`docs/org-profiles.md`](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md) |
| `org-profile/context/organization.md` | Short organization context for the analysis (max. 50 KB) |
| `org-profile/actors/*.yaml` | Your own enterprise actors for threat modeling |
| `org-profile/hooks/*.py` | Scripts for the hooks declared in the profile's `hooks:` block, referenced via `${CLAUDE_PLUGIN_ROOT}/org-profile/hooks/...` |
| `org-profile/package-policy.yaml` | Allow-list: which skills, hooks (including org hook ids), and MCP servers go into the internal package |
| `org-skills/<skill-id>/SKILL.md` | Your own skills, packaged alongside the upstream ones |
| `Makefile` / `scripts/` | Build and fetch logic |
| `.github/workflows/package.yml` / `.gitlab-ci.yml` | CI configuration |
| `ci-requirements.lock` | Hashed, binary-only Python dependencies used by both CI templates |
| `README.example.md` / `docs/MAINTAINER-RUNBOOK.example.md` | Generated repository landing page and maintainer runbook |

**Do not touch:** `upstream/` and `build/` — both are generated.

## What you can customize

Almost everything runs through `org-profile.yaml`:

| Block | What it does |
|---|---|
| `presets`, `default_preset` | How deep a scan goes, which outputs it produces, which guardrails apply |
| `requirements` | Your own requirements catalog, and when a CI run should fail against it |
| `policy` | Which hosts may be reached, whether Opus may be used |
| `branding` | Title, contact and logo on the report cover |
| `llm_context` | Your own markdown documents as analysis context |
| `security_coach` | Your own guidance, shown while code is being written |
| `actors` | Add your own attacker types, switch off the built-in ones |
| `abuse_cases` | Add your own abuse scenarios, switch off the built-in ones |
| `skill_toggles` | Block individual skills — with a reason the user sees on invocation |
| `hooks` | Your own Claude Code hooks |
| `mcp` | Your own MCP servers, for example an internal SAST endpoint |

These blocks require at least **`v0.6.0-beta.1`**, the release the `main`
branch pins. Against an older upstream ref, validation rejects them:

| Block | What it does |
|---|---|
| `banner` | The line shown at session start: your own text, your own info URL, or off |
| `baseline` | Your own secure-coding baseline instead of the bundled one, by URL or git repository |
| `skills` | Ship your own skills — replaces `org-skills/` once available |

On top of that, `package-policy.yaml` decides **what goes into the package at
all**: skills, hooks and MCP servers, each as an `include` or an `exclude` list.
`create-threat-model` cannot be removed.

The difference between the two: `package-policy.yaml` removes something
entirely — the command no longer exists — while `skill_toggles` ships it and
blocks it at runtime with your reason. Use the policy when the command should
not exist; use the toggle when people should learn why.

**Not customizable:** the analysis agents. They belong to the upstream plugin
and call no MCP tools. A configured MCP server is available to the session and
to your own skills — the threat-model pipeline does not query it.

## Invariants that matter

- `package-policy.yaml` is an **allow-list**. A new upstream skill, one of your
  own from `org-skills/`, any hook declared in the profile (`hooks:`), and any
  MCP server declared under `mcp.servers` reach the internal package only once
  their ids are listed under `plugin_surface.skills`, `hooks`, or
  `mcp_servers`.
- The packaged `help` skill and developer-facing README are generated from the final
  `.claude-plugin/package-surface.json` and `config.json` after upstream
  packaging. It lists only included public skills and marks runtime-disabled
  ones. `INTERNAL_REPOSITORY_URL` is the internal packaging repository URL and
  becomes their “More information” link through packaged `config.json`. Keep
  `help` in the skill allowlist; do not edit the upstream help or README.
- **Org hooks run on Claude Code's event layer only.** The `hooks:` block bundles
  your scripts from `org-profile/hooks/` into the built `hooks/hooks.json` and
  records them in `package-surface.json` under `hooks.org`. They never reach the
  analysis pipeline — findings, severity and schemas stay core-owned. Org hook
  ids must be distinct from every hook in the selected upstream ref; validation
  and packaging abort on a collision. To replace upstream hook behavior, omit
  its id from `plugin_surface.hooks.include`, add a hook under a distinct
  `org-...` id, and include that id instead.
- Your own skills must not overwrite an upstream skill name.
  `scripts/package-local.sh` aborts when `org-skills/<name>` already exists under
  `upstream/appsec-advisor/skills/<name>`.
- **Own skills live in `org-skills/`, own MCP servers in the profile.** The
  `mcp:` block is the only path for MCP; the former `org-mcp.json` is no longer
  read. It was copied over the finished `.mcp.json` *after* packaging and
  silently replaced what the profile had produced, including the selection from
  `plugin_surface.mcp_servers`. Upstream now has a `skills:` block too, but it
  is available from `v0.6.0-beta.1`; `org-skills/` remains the mechanism this
  template packages with.
- `org-profile.yaml` is validated against the upstream schema at build time
  (`make validate`). Structural changes must stay schema-conformant
  (`api_version: appsec-advisor.org-profile/v2`).
- The packaged `config.json` contains resolved runtime settings, including
  `skill_toggles`; `.claude-plugin/package-surface.json` records what the
  allowlist actually included or removed. Both are generated and must not be
  edited in place.
- `context/organization.md` is **untrusted reference data** — it can inform the
  analysis but never change severity rules, gates or tool behavior.
- **MCP servers are declared in the `mcp:` block of `org-profile.yaml`** and
  written by the upstream packager, filtered through
  the `plugin_surface.mcp_servers` allowlist. Removing a server id from that
  list removes it from the packaged `.mcp.json`; adding a declared id includes
  it. Tokens belong in `${ENV_VAR}`, which Claude Code expands at load time
  (`${CLAUDE_PLUGIN_ROOT}` is available too) — never hardcode them; a credential
  inside a server URL is rejected at validation. MCP tool *output* is untrusted
  like `organization.md`: it can inform findings but never changes severity
  rules, permissions or tool behavior.
- `INTERNAL_NAME` (default: `acme-appsec`) sets the plugin namespace and the
  command prefix (`/acme-appsec:...`). Keep it consistent across `Makefile`,
  both CI configs and `scripts/package-local.sh`.
- `--description` in `scripts/package-local.sh` and both CI configs contains
  "Acme Corp" — replace it when you fork.

## Common tasks

```bash
make                                  # (or `make help`) lists every target with its description
make lint                             # shellcheck over scripts/ + tests/run.sh (skipped when shellcheck is absent)
make test                             # shell test suite + coverage gate (skipped when tests/ is absent, e.g. in a scaffolded repo)
make check                            # offline gate: lint + test (no network, no upstream fetch)
make release-check                    # release gate: check + check-updates (advisory) + validate + package
make upstream-check                   # read-only drift check: has the build ref moved, is there a newer v* release
make packaging-template-check         # read-only drift check for the pinned packaging-template commit
make baseline-check                   # read-only drift check: does the configured baseline id match its published document
make check-updates                    # check appsec-advisor and baseline updates
make package                          # fetch upstream + build the package + smoke-test it
APPSEC_ADVISOR_REF=v0.6.0-beta.1 make package # pin a specific release
make validate                         # validate org-profile.yaml only
make local-marketplace                # build + generate a local marketplace catalog under build/
make install-local                    # register that catalog and install the plugin at local scope
make reinit                           # reapply the pinned template with existing settings, then package
make reinit APPSEC_ADVISOR_TEMPLATE_REF=<reviewed-commit> # deliberately apply the exact reviewed template commit
REINIT_BUILD=0 make reinit            # reapply template without packaging afterwards
make release-package                    # produce distributable archives + checksums
```

The initializer resolves the packaging-template checkout to an exact Git commit
and writes that pin to generated repositories. `make reinit` reapplies that
same revision; it does not silently execute a newer `main`. Run
`make packaging-template-check`, review the reported drift, then use
`make reinit APPSEC_ADVISOR_TEMPLATE_REF=<reviewed-commit>` (or a reviewed
release tag) to update deliberately. Use the exact commit reported by the check,
not the moving branch name. A successful reinitialization persists that exact
revision again.

When the baseline is kept, the initializer pins the id the published baseline
declares — read from the appsec-foundry baseline through
`scripts/resolve-baseline-id.py` — instead of the id the template carries. The
template's pin is the fallback when the document cannot be read, so keep it
current; `make baseline-check` compares the configured id against the published
one.

Reinitialization refreshes infrastructure directly. For each differing
user-editable template file, it prompts to overwrite, keep, overwrite all
remaining, or keep all remaining. The default is keep; overwritten files are
recoverable from `.reinit-backups/`, and the resulting changes remain
uncommitted for review.

### Package versioning

`PACKAGE_VERSION` is the organization-owned plugin version. It defaults to
`0.1.0` and appears in the session banner, packaged help, `plugin.json`, and
archive filename:

```
Acme AppSec Advisor 1.2.0 · /acme-appsec:help
```

Bump `PACKAGE_VERSION` when publishing a new internal package release. It must
be valid SemVer, for example `1.2.0` or `1.2.0-internal.1`. The upstream release
remains independently pinned by `APPSEC_ADVISOR_REF`; changing upstream no
longer changes the organization package version. In CI, a packaging-repository
tag such as `v1.2.0` becomes the package version. An explicitly set `VERSION`
still overrides `PACKAGE_VERSION` for a one-off backward-compatible build.
The finished manifest records the pinned implementation separately as
`appsec_advisor_core_version`, so `compatibility.core` continues to validate the
upstream core rather than the organization release number.

It also records which upstream revision the package was built from:
`appsec_advisor_core_ref` (tag or branch) and `appsec_advisor_core_commit` (the
exact commit), both omitted when the source is not a Git checkout. A branch
build such as `dev` reuses the same upstream version string across many
commits, so the commit is the only exact identifier. Packaged help and the
packaged README show the same line, and
`cat "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"` reads it from an
installed plugin:

```
acme-appsec 1.2.0
appsec-advisor core 0.6.0-beta.1 (dev @ 9f2c1ab7c3d1)
```

### Following upstream: release or branch

`APPSEC_ADVISOR_REF` is the single knob for "what do we build from". It accepts
a `v*` tag, the literal `latest`, **or a branch name** — `fetch-upstream.sh`
checks both tags and heads, and a branch ref is pulled up to its current tip on
every run (a `--depth 1` detached checkout, so effectively a pull).

Der Initializer bietet zwei Upstream-Kanäle an. **Stable** ist der Standard:
der höchste verfügbare `v*`-Tag wird einmal aufgelöst und konkret im erzeugten
`Makefile` gepinnt. **Development** schreibt `APPSEC_ADVISOR_REF=dev` und folgt
damit bei jedem Build dem aktuellen Branch-Head. Das Template-Repository selbst
pinnt aktuell `v0.6.0-beta.1`; `make reinit` erhält sowohl diesen Upstream-Ref
als auch den exakten Packaging-Template-Pin eines erzeugten Repositories, statt
die Kanalauswahl erneut auszuführen.

```bash
make package                              # upstream v0.6.0-beta.1 (default)
APPSEC_ADVISOR_REF=latest make package    # one-off build from the highest valid SemVer v* tag
APPSEC_ADVISOR_REF=v0.6.0-beta.1 make package # pin a specific release (reproducible)
APPSEC_ADVISOR_REF=dev make package       # follow the upstream dev branch
APPSEC_ADVISOR_REF=main    make package   # follow the default branch
```

For a persistent Stable update, run `make upstream-check`, copy its `latest
release` value into the `APPSEC_ADVISOR_REF := ...` assignment in `Makefile`,
bump `PACKAGE_VERSION`, and run `make release-package`. A command-line
`APPSEC_ADVISOR_REF=latest` override affects only that invocation and does not
rewrite `Makefile`. With a `dev` ref, a normal `make package` or
`make release-package` fetches the current branch head automatically.

`make upstream-check` adapts to the mode: with a pinned release it reports a
newer release tag; with a branch ref it reports when the branch tip has moved
past your local checkout.

## Testing the plugin locally

```bash
claude --plugin-dir build/acme-appsec
# then inside Claude Code:
/acme-appsec:check-permissions --update
/acme-appsec:create-threat-model
```

To test the Marketplace installation path instead of sideloading with
`--plugin-dir`, run `make install-local`. It generates a disposable catalog at
`build/.claude-plugin/marketplace.json`; it does not modify or replace the
organization's central Marketplace.

## CI variables

| Variable | Default | Meaning |
|---|---|---|
| `APPSEC_ADVISOR_URL` | upstream GitHub | Upstream repository or an internal fork |
| `APPSEC_ADVISOR_REF` | `v0.6.0-beta.1` | Pinned upstream release |
| `INTERNAL_NAME` | `acme-appsec` | Plugin name and command namespace |
| `PACKAGE_VERSION` | `0.1.0` | Organization-owned plugin release; a `v*` packaging tag overrides it in CI |
| `VERSION` | empty | Optional one-off override of `PACKAGE_VERSION` |
