# Entwicklerdokumentation

## Branch-Modell

Aktuell verwendet das Packaging-Repository ausschließlich `main`. Die
`Makefile` pinnt `appsec-advisor` standardmäßig auf `v0.6.0-beta.1`.
Ein langfristiger Entwicklungsbranch kann später bei Bedarf ergänzt werden.

## Lokale Entwicklung

```bash
git switch main
git pull --ff-only
make package
make check
```

`make package` checkt den Upstream auf dem gepinnten Tag aus. Zum Prüfen gegen einen lokalen Upstream-Checkout:

```bash
APPSEC_ADVISOR_SOURCE=/home/mrohr/appsec-advisor make package
```

## Neues Packaging-Repository erzeugen

Voraussetzungen sind Bash 3.2+, Git, Python 3.10+, Make, `sed` und `mktemp`.
Für den optionalen lokalen Erst-Build werden außerdem die Python-Module
`PyYAML` und `jsonschema` benötigt. Das Init-Skript prüft diese Voraussetzungen
und meldet fehlende Komponenten vor dem jeweiligen Arbeitsschritt.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/appsec-foundry/appsec-advisor-packaging-template/main/scripts/init-org-repo.sh)
```
