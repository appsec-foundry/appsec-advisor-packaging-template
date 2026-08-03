# Entwicklerdokumentation

## Branch-Modell

| Packaging-Branch | Zweck | Standard-Ref von `appsec-advisor` |
|---|---|---|
| `main` | Release-Linie | `v0.5.1-beta` (gepinnt) |
| `dev` | Entwicklung | `dev` (aktueller Branch-Tip) |

Entwicklungsarbeit erfolgt auf `dev`. Dort verwendet `make package`
automatisch `APPSEC_ADVISOR_REF=dev`. Für einen Release werden Änderungen nach
`main` übernommen; dessen Build bleibt gegen den unterstützten Upstream-Release
reproduzierbar.

## Lokale Entwicklung

```bash
git switch dev
git pull --ff-only
make package
make check
```

`make package` aktualisiert den Upstream-Checkout auf den aktuellen
`appsec-advisor/dev`-Tip. Zum Prüfen gegen einen lokalen Upstream-Checkout:

```bash
APPSEC_ADVISOR_SOURCE=/home/mrohr/appsec-advisor make package
```

## Neues Entwicklungs-Repository erzeugen

Für ein Scaffold, das ebenfalls gegen `appsec-advisor/dev` baut:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/matthiasrohr/appsec-advisor-packaging-template/dev/scripts/init-org-repo.sh)
```

Der `main`-URL des Skripts ist ausschließlich für releaseorientierte
Scaffolds vorgesehen.
