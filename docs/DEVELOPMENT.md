# Entwicklerdokumentation

## Branch-Modell

| Packaging-Branch | Zweck | Standard-Ref von `appsec-advisor` |
|---|---|---|
| `main` | Release-Linie | `v0.6.0-beta.1` |
| `dev` | Entwicklung | `v0.6.0-beta.2` (Prerelease in Entwicklung) |

Entwicklungsarbeit erfolgt auf `dev`. Dort verwendet `make package`
automatisch `APPSEC_ADVISOR_REF=v0.6.0-beta.2`. Nach dem Merge nach `main`
baut derselbe Build gegen `v0.6.0-beta.1`. Beide Pins stehen in der
`Makefile` und werden hochgezogen, sobald upstream ein neues Release taggt.

## Lokale Entwicklung

```bash
git switch dev
git pull --ff-only
make package
make check
```

`make package` checkt den Upstream auf dem gepinnten Tag aus. Zum Prüfen gegen einen lokalen Upstream-Checkout:

```bash
APPSEC_ADVISOR_SOURCE=/home/mrohr/appsec-advisor make package
```

## Neues Entwicklungs-Repository erzeugen

Für ein Scaffold, das ebenfalls gegen `appsec-advisor/dev` baut:

```bash
APPSEC_ADVISOR_TEMPLATE_REF=dev bash <(curl -fsSL https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
```

Ohne `APPSEC_ADVISOR_TEMPLATE_REF=dev` erzeugt der `main`-URL ein
releaseorientiertes Scaffold.
