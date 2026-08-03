# Entwicklerdokumentation

## Branch-Modell

| Packaging-Branch | Zweck | Standard-Ref von `appsec-advisor` |
|---|---|---|
| `main` | Release-Linie | `main` |
| `dev` | Entwicklung | `dev` (aktueller Branch-Tip) |

Entwicklungsarbeit erfolgt auf `dev`. Dort verwendet `make package`
automatisch `APPSEC_ADVISOR_REF=dev`. Nach dem Merge nach `main` verwendet
derselbe Build automatisch `APPSEC_ADVISOR_REF=main`.

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
APPSEC_ADVISOR_TEMPLATE_REF=dev bash <(curl -fsSL https://raw.githubusercontent.com/matthiasrohr/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
```

Ohne `APPSEC_ADVISOR_TEMPLATE_REF=dev` erzeugt der `main`-URL ein
releaseorientiertes Scaffold.
