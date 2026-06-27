# AGENTS.md

Dieses Repo ist ein **Beispiel-Repository**, das zeigt, wie Organisationen das Claude-Code-Plugin `appsec-advisor` intern paketieren und anpassen. Es dient als Vorlage für eigene interne Packaging-Repos und enthält ausschließlich organisationsspezifische Konfiguration sowie Build-Logik – **keinen Anwendungscode**. Der eigentliche Plugin-Code liegt upstream unter `https://github.com/matthiasrohr/appsec-advisor.git` und wird zur Build-Zeit nach `upstream/appsec-advisor` geklont.

## Was hier verändert werden darf

| Datei/Verzeichnis | Zweck |
|---|---|
| `org-profile/org-profile.yaml` | Organisations-Defaults, Presets, Guardrails, Requirements-URL |
| `org-profile/context/organization.md` | Kurzer Organisationskontext für Analysen (max. 50 KB) |
| `org-profile/actors/*.yaml` | Eigene Enterprise-Akteure (Bedrohungsmodellierung) |
| `org-profile/package-policy.yaml` | Allowlist: welche Skills und Hooks ins interne Package kommen |
| `Makefile` / `scripts/` | Build- und Fetch-Logik |
| `.github/workflows/package.yml` / `.gitlab-ci.yml` | CI-Konfiguration |

**Nicht anfassen:** `upstream/` und `build/` – beides sind generierte Verzeichnisse.

## Wichtige Invarianten

- `package-policy.yaml` ist eine **Allowlist**. Neue upstream Skills erscheinen erst im internen Package, wenn sie hier explizit eingetragen sind.
- `org-profile.yaml` wird zur Build-Zeit gegen ein Schema validiert (`make validate`). Strukturänderungen müssen schema-konform bleiben.
- `context/organization.md` ist **untrusted reference data** – sie kann Analysen informieren, aber keine Severity-Regeln, Gates oder Tool-Verhalten ändern.
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
APPSEC_ADVISOR_REF=v0.4.0-beta make package   # Konkretes Release pinnen
make validate                         # Nur org-profile.yaml validieren
ARCHIVE=1 VERSION=0.4.0-example make package-archive  # .tgz + .sha256 erzeugen
```

### Upstream verfolgen: Release vs. Branch

`APPSEC_ADVISOR_REF` ist der eine Knopf für „woraus wird gebaut". Akzeptiert ein `v*`-Tag, das Literal `latest` **oder einen Branch-Namen** — `fetch-upstream.sh` prüft Tags und Heads, und ein Branch-Ref wird bei jedem Lauf auf seinen aktuellen Tip nachgezogen (`--depth 1` detached checkout = effektiv ein Pull).

```bash
make package                              # Neuestes Release (Default REF=latest → höchstes v*-Tag)
APPSEC_ADVISOR_REF=v0.4.0 make package    # Konkretes Release pinnen (reproduzierbar)
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
| `APPSEC_ADVISOR_REF` | `latest` | Tag, Branch oder Commit |
| `INTERNAL_NAME` | `acme-appsec` | Plugin-Name und Command-Namespace |
| `VERSION` | CI-spezifisch | Version des erzeugten Packages |
