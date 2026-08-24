#!/usr/bin/env bash
# Refresh a scaffolded packaging repository from the current template while
# asking before replacing differing organization-owned files.
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
banner_enabled = True
banner = False
for line in lines:
    if line and not line[0].isspace():
        key = line.split(":", 1)[0]
        inside = key == "organization"
        baseline = key == "baseline"
        banner = key == "banner"
        continue
    if inside:
        match = re.match(r"^  (id|name|owner):\s*(.+?)\s*$", line)
        if match:
            organization[match.group(1)] = scalar(match.group(2))
    if baseline and re.match(r"^  enabled:\s*false(?:\s+#.*)?$", line):
        baseline_enabled = False
    if banner and re.match(r"^  enabled:\s*false(?:\s+#.*)?$", line):
        banner_enabled = False

policy_path = root / "org-profile" / "package-policy.yaml"
try:
    policy_lines = policy_path.read_text(encoding="utf-8").splitlines()
except UnicodeDecodeError as error:
    print(
        f"ERROR: {policy_path} is not valid UTF-8 at byte {error.start}; repair it before reinitializing",
        file=sys.stderr,
    )
    raise SystemExit(2)

hook_mode = None
hook_names = set()
inside_hooks = False
inside_selection = False
for line in policy_lines:
    if re.match(r"^  hooks:\s*(?:#.*)?$", line):
        inside_hooks = True
        inside_selection = False
        continue
    if inside_hooks and line and not line.startswith(" "):
        break
    if inside_hooks:
        match = re.match(r"^    (include|exclude):\s*(?:#.*)?$", line)
        if match:
            hook_mode = match.group(1)
            inside_selection = True
            continue
        if inside_selection:
            item = re.match(r"^      -\s+([A-Za-z0-9_.-]+)\s*(?:#.*)?$", line)
            if item:
                hook_names.add(item.group(1))
            elif line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip(" ")) <= 4:
                inside_selection = False

if hook_mode == "include":
    banner_packaged = "session-banner" in hook_names
elif hook_mode == "exclude":
    banner_packaged = "session-banner" not in hook_names
else:
    banner_packaged = True

makefile = (root / "Makefile").read_text(encoding="utf-8")
match = re.search(r"^INTERNAL_NAME\s*\?=\s*([a-z0-9][a-z0-9-]*)\s*$", makefile, re.MULTILINE)
plugin_name = match.group(1) if match else ""
match = re.search(r"^PACKAGE_VERSION\s*\?=\s*([^\s#]+)\s*$", makefile, re.MULTILINE)
package_version = match.group(1) if match else ""
if not package_version:
    match = re.search(r"^VERSION\s*\?=\s*([^\s#]+)\s*$", makefile, re.MULTILINE)
    package_version = match.group(1) if match else "0.1.0"
match = re.search(r"^INTERNAL_REPOSITORY_URL\s*\?=\s*([^\s#]+)?\s*$", makefile, re.MULTILINE)
repository_url = (match.group(1) or "") if match else ""
values = [
    organization.get("name", ""),
    organization.get("id", ""),
    plugin_name,
    package_version,
    organization.get("owner", ""),
    "true" if (root / "org-profile" / "requirements.yaml").is_file() else "false",
    "true" if baseline_enabled else "false",
    "true" if banner_enabled and banner_packaged else "false",
    repository_url,
]
if any(not value for value in values[:5]):
    print("ERROR: cannot recover organization name/id/owner, INTERNAL_NAME or PACKAGE_VERSION from this repository", file=sys.stderr)
    raise SystemExit(2)
if not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", values[1]):
    print("ERROR: existing organization id is not safe for reinitialization", file=sys.stderr)
    raise SystemExit(2)
for value in values:
    os.write(1, value.encode("utf-8") + b"\0")
PY
)

if [ "${#SETTINGS[@]}" -ne 9 ]; then
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
APPSEC_REINIT_PACKAGE_VERSION="${SETTINGS[3]}" \
APPSEC_REINIT_OWNER="${SETTINGS[4]}" \
APPSEC_REINIT_DEMO="${SETTINGS[5]}" \
APPSEC_REINIT_BASELINE="${SETTINGS[6]}" \
APPSEC_REINIT_STATUSLINE="${SETTINGS[7]}" \
APPSEC_REINIT_REPOSITORY_URL="${SETTINGS[8]}" \
APPSEC_REINIT_BUILD="${REINIT_BUILD}" \
  "${TEMPLATE_SOURCE}/scripts/init-org-repo.sh"
