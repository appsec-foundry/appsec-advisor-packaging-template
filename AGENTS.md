# AGENTS.md

Dieses Repo ist ein **Beispiel-Repository**, das zeigt, wie Organisationen das Claude-Code-Plugin `appsec-advisor` intern paketieren und anpassen. Es dient als Vorlage für eigene interne Packaging-Repos und enthält ausschließlich organisationsspezifische Konfiguration sowie Build-Logik – **keinen Anwendungscode**. Der eigentliche Plugin-Code liegt upstream unter `https://github.com/matthiasrohr/appsec-advisor.git` und wird zur Build-Zeit nach `upstream/appsec-advisor` geklont.

## Was hier verändert werden darf

| Datei/Verzeichnis | Zweck |
|---|---|
| `org-profile/org-profile.yaml` | Organisations-Defaults, Presets, Guardrails, Requirements-URL — dazu CI-Gates (`requirements.gate`, `guardrails.fail_on`), Run-Policy (`policy.url_allowlist`), Security-Coaching (`security_coach`) und Org-Hooks (`hooks:`). Siehe upstream [`docs/org-profiles.md`](https://github.com/matthiasrohr/appsec-advisor/blob/main/docs/org-profiles.md) |
| `org-profile/context/organization.md` | Kurzer Organisationskontext für Analysen (max. 50 KB) |
| `org-profile/actors/*.yaml` | Eigene Enterprise-Akteure (Bedrohungsmodellierung) |
| `org-profile/hooks/*.py` | Skripte für org-deklarierte Claude-Code-Hooks (`hooks:` im Profil), referenziert via `${CLAUDE_PLUGIN_ROOT}/org-profile/hooks/...` |
| `org-profile/package-policy.yaml` | Allowlist: welche Skills und Hooks (inkl. Org-Hook-IDs) ins interne Package kommen |
| `org-skills/<skill-id>/SKILL.md` | Eigene Organisations-Skills, die zusätzlich zu upstream paketiert werden |
| `org-mcp.json` | Optionale MCP-Server (z.B. interne SAST/SCA-Endpunkte), die als `.mcp.json` ins gebaute Plugin kopiert werden. Opt-in: standardmäßig nicht vorhanden. Secrets nur via `${ENV_VAR}` |
| `Makefile` / `scripts/` | Build- und Fetch-Logik |
| `.github/workflows/package.yml` / `.gitlab-ci.yml` | CI-Konfiguration |

**Nicht anfassen:** `upstream/` und `build/` – beides sind generierte Verzeichnisse.

## Wichtige Invarianten

- `package-policy.yaml` ist eine **Allowlist**. Neue upstream Skills, eigene Skills aus `org-skills/` und im Profil deklarierte Org-Hooks (`hooks:`) erscheinen erst im internen Package, wenn ihre ID hier unter `plugin_surface.skills`/`hooks` explizit eingetragen ist.
- **Org-Hooks laufen nur auf Claude Codes Event-Layer.** Der `hooks:`-Block bündelt Org-Skripte (aus `org-profile/hooks/`) in die gebaute `hooks/hooks.json` und trägt sie in `package-surface.json` unter `hooks.org` ein. Sie erreichen nie die Analyse-Pipeline — Findings, Severity und Schemas bleiben core-owned.
- Eigene Skills dürfen keine upstream Skill-Namen überschreiben. `scripts/package-local.sh` bricht ab, wenn `org-skills/<name>` bereits unter `upstream/appsec-advisor/skills/<name>` existiert.
- `org-profile.yaml` wird zur Build-Zeit gegen ein Schema validiert (`make validate`). Strukturänderungen müssen schema-konform bleiben (`api_version: appsec-advisor.org-profile/v2`).
- `context/organization.md` ist **untrusted reference data** – sie kann Analysen informieren, aber keine Severity-Regeln, Gates oder Tool-Verhalten ändern.
- `org-mcp.json` ist **opt-in und enthält keine Secrets**. Wenn vorhanden, muss es ein JSON-Objekt mit Top-Level-Key `mcpServers` sein (sonst bricht der Build ab) und wird vor dem Smoke-Test unverändert nach `build/<name>/.mcp.json` kopiert. Tokens und interne URLs müssen über `${ENV_VAR}` referenziert werden (Claude Code expandiert sie beim Laden; `${CLAUDE_PLUGIN_ROOT}` ist ebenfalls verfügbar) – niemals hardcoden. MCP-Tool-*Output* ist wie `organization.md` untrusted: informiert Findings, ändert aber keine Severity-Regeln, Permissions oder Tool-Verhalten.
- `INTERNAL_NAME` (Default: `acme-appsec`) bestimmt den Plugin-Namespace und den Command-Prefix (`/acme-appsec:...`). Muss konsistent in `Makefile`, beiden CI-Configs und `scripts/package-local.sh` gesetzt werden.
- `--description` in `scripts/package-local.sh` und beiden CI-Configs enthält „Acme Corp" – beim Forken ersetzen.

## Typische Aufgaben

```bash
make                                  # (oder `make help`) listet alle Targets mit Beschreibung
make lint                             # shellcheck über scripts/ + tests/run.sh (übersprungen, wenn shellcheck fehlt)
make test                             # Shell-Test-Suite + Coverage-Gate (übersprungen, wenn tests/ fehlt, z.B. in scaffolded Repos)
make check                            # Offline-Gate: lint + test (kein Netzwerk, kein Upstream-Fetch)
make release-check                    # Release-Boundary-Gate: check + upstream-check (advisory) + validate + package (baut ein sauberes Plugin gegen Upstream)
make upstream-check                   # Read-only Drift-Check: meldet, ob der Build-Ref auf einen neuen Commit gewandert ist oder ein neueres v*-Release existiert (Exit 0=aktuell, 1=Drift, 2=Fehler)
make package                          # Upstream holen + Package bauen + Smoke-Test
APPSEC_ADVISOR_REF=v0.5.0-beta make package   # Konkretes Release pinnen
make validate                         # Nur org-profile.yaml validieren
ARCHIVE=1 ORG_REV=3 make package-archive  # .tgz + .sha256 erzeugen
```

### Versionierung des Packages

Die Version wird von `package-local.sh` aus der Upstream-Herkunft plus einem Org-Revisionszähler abgeleitet:

```
<upstream-version>+<org-id>.<org-rev>     z.B. 0.5.0-beta+acme.3
```

Linke Hälfte: der Tag des Upstream-Checkouts (`git describe --tags --exact-match`, `v` gestrippt). Steht der Build auf einem Branch-Tip statt auf einem Tag, gibt es keinen Tag zu benennen → Fallback `0.0.0-<ref>.g<shortsha>`. Rechte Hälfte ist SemVer-Build-Metadata: `ORG_ID` (Default: erstes Segment von `INTERNAL_NAME`) und `ORG_REV` (Default `1`).

Bump-Regel: `ORG_REV` hochzählen, wenn sich nur Org-Inhalte ändern (`org-profile/`, `org-skills/`, `org-mcp.json`, `package-policy.yaml`); wandert `APPSEC_ADVISOR_REF`, ändert sich die linke Hälfte und `ORG_REV` startet wieder bei 1. In CI setzt die Pipeline `ORG_REV` auf den Repo-Tag (Tag-Pipeline) bzw. die Commit-SHA. Ein explizit gesetztes `VERSION` überschreibt den ganzen String.

### Upstream verfolgen: Release vs. Branch

`APPSEC_ADVISOR_REF` ist der eine Knopf für „woraus wird gebaut". Akzeptiert ein `v*`-Tag, das Literal `latest` **oder einen Branch-Namen** — `fetch-upstream.sh` prüft Tags und Heads, und ein Branch-Ref wird bei jedem Lauf auf seinen aktuellen Tip nachgezogen (`--depth 1` detached checkout = effektiv ein Pull).

```bash
make package                              # Das gepinnte Release (Default REF, aktuell v0.5.0-beta)
APPSEC_ADVISOR_REF=latest make package    # Stattdessen dem höchsten v*-Tag folgen
APPSEC_ADVISOR_REF=v0.5.0-beta make package # Konkretes Release pinnen (reproduzierbar)
APPSEC_ADVISOR_REF=develop make package   # Branch-Tip verfolgen (z.B. Upstream-Dev-Branch)
APPSEC_ADVISOR_REF=main    make package   # Default-Branch verfolgen
```

`make upstream-check` passt sich dem Modus an: bei `REF=latest` meldet es ein neueres Release-Tag; bei einem Branch-Ref meldet es, wenn der Branch-Tip über deinen lokalen Checkout hinausgewandert ist.

## Plugin lokal testen

```bash
claude --plugin-dir build/acme-appsec
# dann in Claude Code:
/acme-appsec:check-permissions --update
/acme-appsec:create-threat-model
```

## CI-Variablen

| Variable | Default | Bedeutung |
|---|---|---|
| `APPSEC_ADVISOR_URL` | upstream GitHub | Upstream-Repo oder interner Fork |
| `APPSEC_ADVISOR_REF` | `v0.5.0-beta` | Tag, Branch oder `latest` |
| `INTERNAL_NAME` | `acme-appsec` | Plugin-Name und Command-Namespace |
| `ORG_REV` | Repo-Tag bzw. Commit-SHA | Org-Revision in der abgeleiteten Version |
| `VERSION` | abgeleitet | Überschreibt die abgeleitete Version komplett |
