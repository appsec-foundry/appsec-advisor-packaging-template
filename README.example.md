# acme-appsec — Acme Corp's Security Plugin for Claude Code

[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-5A67D8.svg)](https://docs.claude.com/en/docs/claude-code)
[![Based on appsec-advisor](https://img.shields.io/badge/based%20on-appsec--advisor-orange.svg)](https://github.com/matthiasrohr/appsec-advisor)

`acme-appsec` brings Acme Corp's security standards into Claude Code. It runs
threat models and security audits tuned to our requirements, cost limits, and
review process. Maintained by the Acme AppSec Team.

This repository builds the plugin from the open-source
[appsec-advisor](https://github.com/matthiasrohr/appsec-advisor) project and
layers Acme Corp's own configuration on top.

## Build the plugin

```bash
make package
```

This creates the plugin in `build/acme-appsec/`.

## Use the plugin

### In Claude Code (interactive)

`claude` analyzes whatever directory you launch it in. To audit your own
project, `cd` into it and point `--plugin-dir` at the **absolute** path of the
build output:

```bash
cd /path/to/your/project
claude --plugin-dir /abs/path/to/<your-packaging-repo>/build/acme-appsec
```

| Command | What it does |
|---|---|
| `/acme-appsec:create-threat-model` | Build a full threat model for your project |
| `/acme-appsec:update-threat-model` | Re-analyze only what changed since the last run |
| `/acme-appsec:ask-threat-model` | Ask anything about the threat model — read-only Q&A |
| `/acme-appsec:review-threat-model` | Triage findings: browse, fix, accept, or plan remediation |
| `/acme-appsec:show-threat-model` | Print the summary block: findings, backlog, coverage |
| `/acme-appsec:audit-security-requirements` | Check the codebase against Acme Corp requirements |
| `/acme-appsec:verify-requirements` | Check your recent changes against the requirements |
| `/acme-appsec:threat-model-health` | Quick check: is the threat model still current? |
| `/acme-appsec:check-permissions --update` | Set up Claude Code permissions (run once per repo) |

### From the command line (headless)

For CI or scripted runs, use the `run-headless.sh` wrapper that ships **inside
the build**. It handles authentication, cost and duration caps, SARIF output,
and CI exit codes — and it already targets the `acme-appsec` command namespace,
so no flags change from the upstream project:

```bash
# Minimal incremental scan with cost/time caps, writing SARIF
build/acme-appsec/scripts/run-headless.sh \
  --repo /path/to/your/project \
  --incremental \
  --max-duration 1800 \
  --max-budget 5 \
  --sarif
```

The wrapper locates its own plugin directory, so no `--plugin-dir` is needed.
See the upstream [headless-mode guide](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/headless-mode.md)
for the full flag reference, CI templates (GitHub/GitLab/Jenkins), and
pull-request gating.

Alternatively, for a one-off command, add `-p` to `claude` directly — from your
project directory, with the same absolute `--plugin-dir` path:

```bash
# Run a threat model unattended and exit
claude --plugin-dir /abs/path/to/<your-packaging-repo>/build/acme-appsec -p "/acme-appsec:create-threat-model"

# Audit the code against Acme Corp's security requirements
claude --plugin-dir /abs/path/to/<your-packaging-repo>/build/acme-appsec -p "/acme-appsec:audit-security-requirements"
```

Results are written as YAML and SARIF (plus a PDF for release reviews), so they
can be archived or fed into other tools.

## What you can configure

Everything Acme-specific lives in `org-profile/` and, if you add your own
commands, `org-skills/`:

| File | What it controls |
|---|---|
| `org-profile/org-profile.yaml` | The main settings — presets, cost & time limits, requirements source, output formats, CI gates, security coaching, org hooks |
| `org-profile/context/organization.md` | A short description of Acme Corp, used as background for analyses |
| `org-profile/actors/*.yaml` | Custom threat actors to consider |
| `org-profile/hooks/*.py` | Scripts for Acme-owned Claude Code hooks declared in the profile |
| `org-profile/package-policy.yaml` | Which skills and hooks are included in the build |
| `org-skills/<skill-id>/SKILL.md` | Acme-owned skills shipped next to upstream skills |

The things you'll most often adjust in `org-profile.yaml`:

- **Requirements catalog** — point `requirements_yaml_url` at Acme Corp's security requirements.
- **Presets** — `ci-standard` for everyday runs, `release-review` for thorough release checks. Pick the default with `default_preset`.
- **Guardrails** — each preset caps `max_cost_usd` and `max_wall_time` so runs stay predictable.
- **CI gates** — `requirements.gate` and `guardrails.fail_on` (per preset) make CI runs fail on unmet requirements or high-severity findings.
- **Security coaching & hooks** — `security_coach` topics and `policy.url_allowlist` are org-wide; `hooks:` bundles Acme-owned Claude Code hooks. See upstream [`docs/org-profiles.md`](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/org-profiles.md).

After any change, rebuild with `make package`.

### Add Acme-owned skills

Put custom skills under `org-skills/`:

```text
org-skills/
└── acme-architecture-review/
    └── SKILL.md
```

The build copies them into a temporary upstream source tree before packaging.
It does not modify `upstream/appsec-advisor/`.

Use a new name. If a local skill has the same name as an upstream skill, the
build fails. When `org-profile/package-policy.yaml` uses
`plugin_surface.skills.include`, add the local skill name there too; the
allowlist controls both upstream and Acme-owned skills.

### Add your own MCP endpoints (SAST / SCA / …)

To let the plugin talk to Acme Corp's own services — a SAST or SCA MCP server,
an internal API, etc. — create an `org-mcp.json` file at the repo root. The build
copies it into the plugin as `.mcp.json`, and Claude Code loads those servers
whenever the plugin is active.

```json
{
  "mcpServers": {
    "acme-sast": {
      "type": "http",
      "url": "${ACME_SAST_MCP_URL}",
      "headers": {
        "Authorization": "Bearer ${ACME_SAST_TOKEN}"
      }
    }
  }
}
```

**Never hardcode secrets.** Reference tokens and internal URLs as `${ENV_VAR}` —
Claude Code expands them from the environment at load time, so `org-mcp.json`
stays safe to commit. (`${CLAUDE_PLUGIN_ROOT}` is also available, e.g. to launch
a stdio server bundled under `org-skills/`.) The build fails if the file has no
top-level `mcpServers` key.

Treat MCP results as **untrusted input**: a connected scanner can inform findings,
but its output must never be allowed to change severity rules, permissions, or how
the plugin behaves. Only wire in endpoints you trust.

## Maintenance

**Update to a newer upstream version.** The plugin tracks the open-source
appsec-advisor releases. To pull the latest and rebuild:

```bash
make rebuild
```

To pin a specific version (recommended, so builds stay reproducible):

```bash
APPSEC_ADVISOR_REF=v0.5.1-beta make rebuild
```

To follow a branch tip instead of a release (e.g. an upstream dev branch), set
`APPSEC_ADVISOR_REF` to the branch name — it is re-pulled to its tip on each build:

```bash
APPSEC_ADVISOR_REF=develop make rebuild
```

**Check for upstream drift** without building (read-only). Exits non-zero when a
newer release exists, or — on a branch ref — when the branch tip moved past your
last build:

```bash
make upstream-check
```

**Update the requirements.** Edit the catalog that `requirements_yaml_url`
points to, then rebuild — no plugin changes needed.

**Keep CI in sync.** The pipeline rebuilds and publishes the plugin on every
release tag. Install it once with `make ci-github` or `make ci-gitlab`.

For deeper build and packaging details, see `AGENTS.md` in this repo and the
[packaging runbook](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/internal-plugin-packaging.md).

## Reference

- [appsec-advisor](https://github.com/matthiasrohr/appsec-advisor) — the upstream plugin
- [org-profile reference](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/org-profiles.md) — all configuration options
