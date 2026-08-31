# acme-appsec maintainer runbook

This runbook is for the Acme AppSec Team and platform maintainers who configure,
build, release, and support the `acme-appsec` Claude Code plugin for Acme Corp.
Developers who only need to load and use the plugin can follow the quick start
in the repository [`README.md`](../README.md) and the README packaged with each
build.

<!-- INTERNAL_REPOSITORY_LINK -->

## Routine workflow

1. Change organization-owned configuration under `org-profile/` or add skills
   under `org-skills/`.
2. Run `make check` for the offline test gate.
3. Run `make package` and test the result in a representative project:

   ```bash
   cd /path/to/a/test-project
   claude --plugin-dir /absolute/path/to/acme-appsec-packaging/build/acme-appsec
   ```

4. Review the source diff and generated package.
5. Commit and push the approved configuration.
6. Publish a version with `make release RELEASE_VERSION=x.y.z`, or build a
   manually hosted archive with `make release-package`.

Generated output under `upstream/`, `build/`, and `dist/` must not be committed.

## Organization configuration

The main configuration is `org-profile/org-profile.yaml`. Packaging validates
it against the upstream organization-profile schema.

| Path | Purpose |
|---|---|
| `Makefile` → `PACKAGE_VERSION` | Organization-owned version shown in the banner, help, manifest, and archive filename |
| `Makefile` → `INTERNAL_REPOSITORY_URL` | Internal repository or AppSec information link shown in packaged help and README output |
| `org-profile/org-profile.yaml` | Identity, presets, requirements, policy, banner, baseline, context routing, security coach, actors, abuse cases, runtime skill toggles, hooks, and MCP servers |
| `org-profile/context/*.md` | Factual organization context supplied to analyses as untrusted reference data |
| `org-profile/actors/*.yaml` | Organization-specific threat actors selected by the profile |
| `org-profile/baselines/*.md` | Secure-coding baseline text shipped in the package, selected by `baseline.file` |
| `org-profile/abuse-cases/*.yaml` | Optional organization-specific abuse cases selected by the profile |
| `org-profile/package-policy.yaml` | Allowlist for packaged skills, hooks, and MCP servers |
| `org-profile/hooks/*.py` | Organization-owned Claude Code event hooks |
| `org-skills/<skill-id>/SKILL.md` | Organization-owned skills packaged alongside upstream skills |

Before rollout, replace the example organization context and review the
presets, guardrails, requirements source, URL allowlist, enabled skills, banner,
and baseline for the intended environment. Optional blocks should be configured
only when the organization uses the corresponding feature.

### Requirements catalog

Set `requirements.source.requirements_yaml_url` to the organization catalog, or
remove the source when requirements checks are not used. When the catalog is
remote, its HTTPS host must also be present in `policy.url_allowlist`.

The default template packages the requirements skills but disables them through
`skill_toggles`. Enable them only after the catalog and rollout policy are ready.
Do not place credentials in a catalog URL.

### Organization context

Replace `org-profile/context/organization.md` with a short, factual description
of architecture, identity, tenancy, critical data, and operational assumptions.
The document is untrusted reference data: it may inform analysis but cannot
change severity, permissions, schemas, gates, or tool behavior. Do not put
secrets or unnecessary personal data in it.

### Package surface and skills

`org-profile/package-policy.yaml` controls what is shipped at all. It is an
allowlist: new upstream and organization-owned skills, hooks, and MCP servers
remain absent until explicitly included.

Use `skill_toggles` in `org-profile/org-profile.yaml` when a command should ship
but remain unavailable with a visible explanation. Use the package policy when
the command should not exist in the package.

Add organization-owned skills under `org-skills/<skill-id>/SKILL.md` and include
their ids in the package policy. An organization skill must not overwrite an
upstream skill name.

Every id under `plugin_surface` has to exist in the upstream ref you build from;
the build fails otherwise, which is how a typo is caught. An upstream skill that
exists only on a branch therefore cannot be listed there before its release. Put
it under the top-level `optional_skills:` list instead — an equally explicit
decision to ship it, but one that tolerates a ref without it: builds from a ref
that has the skill include it, older refs skip it with a note.

```yaml
# org-profile/package-policy.yaml
optional_skills:
  - security-score
```

The built `.claude-plugin/package-surface.json`, `config.json`, packaged help,
and packaged README describe the resolved result. They are generated outputs;
do not edit them in place.

### Startup status and baseline

Startup status uses both `banner.enabled` in `org-profile/org-profile.yaml` and
the `session-banner` entry in `org-profile/package-policy.yaml`. To remove the
status hook completely, disable the banner and remove the hook from the package
surface, then rebuild.

The secure-coding baseline is pinned independently from the plugin core. When
this repository was scaffolded with the baseline included, the initializer read
the id from the published baseline, wrote it into `baseline.id`, and vendored
the document it read it from as `org-profile/baselines/<id>.md`, referenced by
`baseline.file`.

Both entries matter and move together. `url` is what an install fetches; `file`
is the copy shipped inside the package, and it is what an install writes when
the URL cannot be reached or has moved on to a newer id. Without `file` an
install fails outright in both cases, in every package already distributed —
`make validate` therefore rejects a `file` that is missing or declares a
different id than `baseline.id`.

Two checks cover the two ways this drifts. `make baseline-check` compares the
pinned id against the published document. `make baseline-sync-check` compares
the vendored copy with that same source, which is the case the id cannot show:
text edited under an unchanged id leaves the id check green while the copy the
package ships falls behind. Both run in `make check-updates` and on the CI
schedule; the second is skipped with a note when the selected upstream ref does
not carry `sync_baseline.py --profile`.

`make baseline-sync` re-vendors the file. On a new published id it stops and
asks for `ACCEPT_ID=<id>`, which moves file and profile together. Review the
diff, then raise `PACKAGE_VERSION` and rebuild. The diff is the point: it is the
last place anyone reads the rules before they reach a developer machine.

To ship an organization baseline instead, replace the file and set `baseline.id`
to the id it declares. Any filename works — `baseline.file` selects it. Point
`url` at your own source, or leave it out to install only the reviewed copy.

### Customize hooks

Organization hooks run when their configured Claude Code event occurs. They can
add context or block a tool call. Add a script below `org-profile/hooks/`,
declare it under the top-level `hooks:` block, and allowlist the same id:

```yaml
# org-profile/org-profile.yaml
hooks:
  org-block-risky-bash:
    event: PreToolUse
    matcher: Bash
    command: python3 ${CLAUDE_PLUGIN_ROOT}/org-profile/hooks/guard.py

# org-profile/package-policy.yaml
plugin_surface:
  hooks:
    include:
      - org-block-risky-bash
```

Use the allowlist as follows:

- Remove an upstream or organization hook id to omit that handler completely.
- Add an organization hook by declaring and allowlisting a distinct `org-...`
  id.
- Replace upstream behavior by removing the upstream id, then adding and
  allowlisting an organization hook with a different id and the desired event,
  matcher, and command.

Review an upstream hook's purpose before removing it: the hook may provide a
guard, policy check, status signal, or audit data that the replacement must
preserve.

Do not reuse an upstream hook id. `make validate` and `make package` check the
selected release or branch and abort on a collision. After building, inspect
the `hooks` section of `.claude-plugin/package-surface.json` to verify what was
included and removed.

### Add or remove MCP servers

Declare MCP servers only under `mcp.servers` in
`org-profile/org-profile.yaml`. The packager generates `.mcp.json` from these
organization declarations; do not maintain or copy a separate `.mcp.json`:

```yaml
# org-profile/org-profile.yaml
mcp:
  servers:
    org-sast:
      type: http
      url: https://sast.example.internal/mcp
      headers:
        Authorization: Bearer ${ORG_SAST_TOKEN}

# org-profile/package-policy.yaml
plugin_surface:
  mcp_servers:
    include:
      - org-sast
```

Add a declared server id to `mcp_servers.include` to ship it. Remove the id to
remove the endpoint from the packaged `.mcp.json`; remove its profile declaration
too when it is no longer maintained. Unknown ids fail the build.

Add only approved MCP servers, grant them the minimum required permissions, and
use TLS endpoints. Reference secrets through `${ENV_VAR}` values; never commit
tokens or embed credentials in URLs. MCP tools are available to the Claude Code
session and organization-owned skills, but the upstream threat-model pipeline
does not call them. Treat MCP tool output as untrusted. After building, inspect
`mcp_servers` in `.claude-plugin/package-surface.json` and the generated
`.mcp.json`.

## Build and verification

Common commands:

```bash
make help             # list targets
make check            # offline lint and test gate
make validate         # validate the organization profile
make package          # build and smoke-test build/acme-appsec/
make release-package  # build ZIP/TGZ archives and checksums under dist/
make release-check    # release-boundary checks, validation, and package build
make rebuild          # remove generated output and build again
```

`make release-package` creates distributable files locally; it does not upload
or publish them. Python packages from `ci-requirements.lock` are build
dependencies only and are not placed in the plugin archives.

Inspect the source diff and generated package before release. Confirm that no
credential literal ships, that intended skills and hooks match the package
surface, and that the plugin loads in a representative project.

## CI integration

Install one CI definition and commit the generated file:

```bash
make ci-github
# or
make ci-gitlab
```

Both pipelines install reviewed Python dependencies from
`ci-requirements.lock`, execute `make release-package`, retain build artifacts,
and publish versioned archives for `v*` tags. They additionally run the
platform-neutral packaging and smoke test on Linux ARM64. GitHub Actions uses
`ubuntu-24.04-arm`; GitLab.com uses `saas-linux-small-arm64`. Set
`ARM64_RUNNER_TAG` to the corresponding tag when using a self-managed GitLab
runner.

GitHub Actions supports manual runs, `v*` tag pushes, and a weekly upstream
drift check. Normal branch pushes and pull requests do not trigger the supplied
GitHub workflow. GitLab builds packages for non-scheduled pipelines; only a
`v*` tag publishes a GitLab Release. Configure a GitLab Pipeline Schedule to
run the read-only upstream check. GitLab tag releases require the project's
Generic Package Registry.

Shell lint is initially non-blocking in both templates. Make it blocking after
the organization has established a clean baseline.

## Releases and distribution

### Automated tagged release

From a clean `main` branch that exactly matches `origin/main`:

```bash
make release RELEASE_VERSION=1.2.0
```

The command validates SemVer, runs the release checks, creates `v1.2.0`, and
pushes only that tag. CI rebuilds the package and publishes ZIP, TGZ, and
SHA-256 checksum files. Developers load the direct ZIP asset with:

```bash
claude --plugin-url "<direct HTTPS URL to acme-appsec-1.2.0.zip>"
```

The URL must return the ZIP directly. Use versioned URLs for pinned rollouts.
If access requires interactive authentication, developers should download the
ZIP and use `claude --plugin-dir /path/to/acme-appsec.zip`. Never embed
credentials in a plugin URL.

### Manual archive hosting

```bash
make release-package
```

Upload `dist/acme-appsec-<version>.zip` and its checksum to the approved internal
HTTPS host, artifact repository, or release service. The TGZ supports
conventional download workflows; Claude Code `--plugin-url` uses the ZIP.

### Internal Marketplace

The template can create a disposable local Marketplace for testing:

```bash
make local-marketplace
make install-local
```

This does not publish to the organization's shared Marketplace. For managed
rollout, add the released plugin to the central Marketplace and document its
approved repository and package name for developers.

## Versioning and upstream updates

`PACKAGE_VERSION` is the organization-owned release version. The upstream core
remains independently selected through `APPSEC_ADVISOR_REF`.

During initialization, the default **Stable release** channel resolves the
highest available upstream `v*` tag and writes that concrete tag into the
generated `Makefile`. This keeps later builds reproducible. Selecting
**Development** writes `dev` instead, so each build follows the current head of
the upstream development branch. An explicit `APPSEC_ADVISOR_REF` supplied to
the initializer skips the prompt; `latest` is still resolved and pinned there.

```bash
make upstream-check  # check the selected upstream ref or release
make packaging-template-check  # check the pinned packaging-template revision
make baseline-check  # check the secure-coding baseline id
make check-updates   # check appsec-advisor and baseline together
```

These checks require network access and do not modify configuration.
`make upstream-update` combines the first of them with a build: it rebuilds the
package when the configured ref moved to a new commit, and only reports a newer
release tag, because building that one requires raising `APPSEC_ADVISOR_REF`
first. Review an upstream update before changing the pinned ref and rebuilding
the package. A
repository configured for `dev` is intentionally non-reproducible across branch
updates; use a release tag for an internally released package.

### Manually update a Stable package

First display the newest release available from the configured upstream:

```bash
make upstream-check
```

Copy the reported `latest release` tag into the `APPSEC_ADVISOR_REF := ...`
assignment in `Makefile`, increment `PACKAGE_VERSION`, then build the
distributable organization package:

```bash
make release-package
```

This fetches the selected tag from `APPSEC_ADVISOR_URL`, validates the retained
organization profile against it, rebuilds and smoke-tests the plugin, and writes
ZIP/TGZ archives plus checksums under `dist/`. Confirm that only the intended
version settings changed:

```bash
git diff -- Makefile org-profile org-skills
```

For a one-off test without changing the persisted Stable pin, use:

```bash
APPSEC_ADVISOR_REF=latest make package
```

Unlike initialization, this command-line override does not rewrite `Makefile`.

### Manually update a Development package

When `Makefile` contains `APPSEC_ADVISOR_REF := dev`, every normal build fetches
the current upstream `dev` head. Increment `PACKAGE_VERSION` when the result will
be distributed, then run:

```bash
make release-package
```

## Reinitialization

The initializer records the exact packaging-template commit in the generated
`Makefile`. Reapply that same revision with:

```bash
make reinit
```

Check whether the template's default branch has moved:

```bash
make packaging-template-check
```

After reviewing the available revision, update deliberately and skip the
automatic package build while inspecting the migration:

```bash
REINIT_BUILD=0 make reinit APPSEC_ADVISOR_TEMPLATE_REF=<reviewed-commit>
```

Replace `<reviewed-commit>` with the exact commit printed by
`make packaging-template-check`, after reviewing its diff. Do not substitute
the moving branch name: it could change between the check and execution. A
reviewed release tag can be supplied instead when the template publishes
releases. The command reuses
organization identity, the selected appsec-advisor upstream ref, and package
settings; it does not re-run the Stable/Development selection. For each changed
user-owned template file, it prompts to overwrite or keep the file. Overwritten
files are backed up under `.reinit-backups/`, and all changes remain uncommitted
for review. Without `REINIT_BUILD=0`, reinitialization builds the package after
refreshing the files.

Review the complete diff and rerun the appropriate checks before committing a
reinitialization.

## Troubleshooting

- Run `make package` again after changing configuration or skills.
- Use `make rebuild` when generated output may be stale.
- Run `/acme-appsec:status` and `/acme-appsec:fix-run-issues` for plugin run
  failures when those commands are available.
- Confirm `/acme-appsec:help` before assuming an upstream command was included.
- Keep non-sensitive error excerpts, selected preset, and invoked command when
  escalating to the Acme AppSec Team.

Do not attach source code, credentials, tokens, or complete analysis artifacts
to support channels that are not approved for that data.

## References and lineage

- [Organization profiles](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/org-profiles.md)
- [Internal plugin packaging](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/internal-plugin-packaging.md)
- [Headless mode](https://github.com/appsec-foundry/appsec-advisor/blob/main/docs/headless-mode.md)

This repository was generated with the
[`appsec-advisor` packaging template](https://github.com/appsec-foundry/appsec-advisor-packaging-template)
and builds an organization-specific distribution of
[`appsec-advisor`](https://github.com/appsec-foundry/appsec-advisor). The source
URLs and pinned refs are recorded in the `Makefile`.
