# acme-appsec — Acme Corp's Security Plugin for Claude Code

`acme-appsec` brings Acme Corp's security standards into Claude Code. It runs
threat models and security audits right where you work — already tuned to our
requirements, cost limits, and review process. Maintained by the Acme AppSec Team.

This repository builds the plugin from the open-source
[appsec-advisor](https://github.com/matthiasrohr/appsec-advisor) project and
layers Acme Corp's own configuration on top.

## Build the plugin

```bash
make package
```

This creates the ready-to-use plugin in `build/acme-appsec/`.

## Use the plugin

### In Claude Code (interactive)

Load the plugin once, then run a command from the chat:

```bash
claude --plugin-dir build/acme-appsec
```

| Command | What it does |
|---|---|
| `/acme-appsec:create-threat-model` | Build a full threat model for your project |
| `/acme-appsec:audit-security-requirements` | Check the codebase against Acme Corp requirements |
| `/acme-appsec:verify-requirements` | Check your recent changes against the requirements |
| `/acme-appsec:threat-model-health` | Quick check: is the threat model still current? |
| `/acme-appsec:check-permissions --update` | Set up Claude Code permissions (run once per repo) |

### From the command line (headless)

For CI or scripted runs, drive the same commands without opening the chat:

```bash
# Run a threat model unattended and exit
claude --plugin-dir build/acme-appsec -p "/acme-appsec:create-threat-model"

# Audit the code against Acme Corp's security requirements
claude --plugin-dir build/acme-appsec -p "/acme-appsec:audit-security-requirements"
```

Results are written as YAML and SARIF (plus a PDF for release reviews), so they
can be archived or fed into other tools.

## What you can configure

Everything Acme-specific lives in `org-profile/`:

| File | What it controls |
|---|---|
| `org-profile/org-profile.yaml` | The main settings — presets, cost & time limits, requirements source, output formats |
| `org-profile/context/organization.md` | A short description of Acme Corp, used as background for analyses |
| `org-profile/actors/*.yaml` | Custom threat actors to consider |
| `org-profile/package-policy.yaml` | Which upstream features are included in the build |

The things you'll most often adjust in `org-profile.yaml`:

- **Requirements catalog** — point `requirements_yaml_url` at Acme Corp's security requirements.
- **Presets** — `ci-standard` for everyday runs, `release-review` for thorough release checks. Pick the default with `default_preset`.
- **Guardrails** — each preset caps `max_cost_usd` and `max_wall_time` so runs stay predictable.

After any change, rebuild with `make package`.

## Maintenance

**Update to a newer upstream version.** The plugin tracks the open-source
appsec-advisor releases. To pull the latest and rebuild:

```bash
make rebuild
```

To pin a specific version (recommended, so builds stay reproducible):

```bash
APPSEC_ADVISOR_REF=v0.4.0 make rebuild
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
