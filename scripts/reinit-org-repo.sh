#!/usr/bin/env bash
# Refresh a scaffolded packaging repository from the current template while
# preserving its organization-owned files and settings.
set -euo pipefail

REPO_ROOT="$(pwd)"
TEMPLATE_URL="${APPSEC_ADVISOR_TEMPLATE_URL:-https://github.com/appsec-foundry/appsec-advisor-packaging-template.git}"
TEMPLATE_REF="${APPSEC_ADVISOR_TEMPLATE_REF:-main}"
TEMPLATE_SOURCE="${APPSEC_ADVISOR_TEMPLATE_SOURCE:-}"
REINIT_BUILD="${REINIT_BUILD:-1}"
TEMP_TEMPLATE=""

cleanup() {
  if [ -n "${TEMP_TEMPLATE}" ]; then
    rm -rf "${TEMP_TEMPLATE}"
  fi
}
trap cleanup EXIT

if [ ! -f "${REPO_ROOT}/Makefile" ] || [ ! -f "${REPO_ROOT}/org-profile/org-profile.yaml" ]; then
  echo "ERROR: make reinit must run from a scaffolded packaging repository root" >&2
  exit 2
fi

mapfile -d '' -t SETTINGS < <(PYTHONUTF8=1 python3 - "${REPO_ROOT}" <<'PY'
from pathlib import Path
import json
import os
import re
import sys

root = Path(sys.argv[1])
profile_path = root / "org-profile" / "org-profile.yaml"
try:
    lines = profile_path.read_text(encoding="utf-8").splitlines()
except UnicodeDecodeError as error:
    print(
        f"ERROR: {profile_path} is not valid UTF-8 at byte {error.start}; repair it before reinitializing",
        file=sys.stderr,
    )
    raise SystemExit(2)

def scalar(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith('"'):
        return json.loads(raw)
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1].replace("''", "'")
    return re.split(r"\s+#", raw, maxsplit=1)[0].strip()

organization = {}
inside = False
baseline_enabled = True
baseline = False
for line in lines:
    if line and not line[0].isspace():
        key = line.split(":", 1)[0]
        inside = key == "organization"
        baseline = key == "baseline"
        continue
    if inside:
        match = re.match(r"^  (id|name|owner):\s*(.+?)\s*$", line)
        if match:
            organization[match.group(1)] = scalar(match.group(2))
    if baseline and re.match(r"^  enabled:\s*false(?:\s+#.*)?$", line):
        baseline_enabled = False

makefile = (root / "Makefile").read_text(encoding="utf-8")
match = re.search(r"^INTERNAL_NAME\s*\?=\s*([a-z0-9][a-z0-9-]*)\s*$", makefile, re.MULTILINE)
plugin_name = match.group(1) if match else ""
values = [
    organization.get("name", ""),
    organization.get("id", ""),
    plugin_name,
    organization.get("owner", ""),
    "true" if (root / "org-profile" / "requirements.yaml").is_file() else "false",
    "true" if baseline_enabled else "false",
]
if any(not value for value in values[:4]):
    print("ERROR: cannot recover organization name/id/owner or INTERNAL_NAME from this repository", file=sys.stderr)
    raise SystemExit(2)
if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", values[1]):
    print("ERROR: existing organization id is not safe for reinitialization", file=sys.stderr)
    raise SystemExit(2)
for value in values:
    os.write(1, value.encode("utf-8") + b"\0")
PY
)

if [ "${#SETTINGS[@]}" -ne 6 ]; then
  echo "ERROR: failed to read existing packaging settings" >&2
  exit 2
fi

if [ -z "${TEMPLATE_SOURCE}" ]; then
  TEMP_TEMPLATE="$(mktemp -d "${TMPDIR:-/tmp}/appsec-packaging-template.XXXXXX")"
  echo "==> Fetching packaging template ${TEMPLATE_REF} …"
  git clone --quiet --depth 1 --branch "${TEMPLATE_REF}" "${TEMPLATE_URL}" "${TEMP_TEMPLATE}"
  TEMPLATE_SOURCE="${TEMP_TEMPLATE}"
fi

if [ ! -x "${TEMPLATE_SOURCE}/scripts/init-org-repo.sh" ]; then
  echo "ERROR: template source does not contain scripts/init-org-repo.sh: ${TEMPLATE_SOURCE}" >&2
  exit 2
fi

APPSEC_REINIT_TARGET="${REPO_ROOT}" \
APPSEC_REINIT_ORG_NAME="${SETTINGS[0]}" \
APPSEC_REINIT_ORG_ID="${SETTINGS[1]}" \
APPSEC_REINIT_PLUGIN_NAME="${SETTINGS[2]}" \
APPSEC_REINIT_OWNER="${SETTINGS[3]}" \
APPSEC_REINIT_DEMO="${SETTINGS[4]}" \
APPSEC_REINIT_BASELINE="${SETTINGS[5]}" \
APPSEC_REINIT_BUILD="${REINIT_BUILD}" \
  "${TEMPLATE_SOURCE}/scripts/init-org-repo.sh"
