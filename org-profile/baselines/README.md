# Baselines

This folder holds the reviewed secure-coding baseline shipped by the package.
`baseline.file` in `org-profile/org-profile.yaml` is authoritative: every sync
reads and writes that file, and packaging fails when its `baseline-id:` differs
from `baseline.id`.

The initializer persists one source mode in the Makefile:

- `aiscb`: vendor the generic [AI Secure Coding Baseline](https://github.com/appsec-foundry/aiscb).
- `organization-git`: temporarily fetch a Git URL/ref and copy one composed
  baseline plus optional skill packs.
- `organization-https`: download exactly one composed HTTPS document; no
  skills or archives are accepted.
- `disabled`: keep baseline installation disabled.

The same commands work for every enabled mode:

```bash
make baseline-sync-check       # read-only; any reported drift makes Make fail
make baseline-sync             # apply same-id text/skill changes
ACCEPT_ID=acme-sec-2.0.0 make baseline-sync  # accept a new id
```

Review every resulting diff before committing it. The tracked copy is the
offline fallback and the exact baseline carried by a released package.

## Generic AISCB mode

The template starts in `BASELINE_SOURCE_KIND=aiscb`. The initializer resolves
the published ID and vendors the same document as
`baselines/secure-coding-baseline.md`. The profile may retain the upstream HTTPS
URL for explicit developer refreshes; the package always carries the reviewed
file too.

For rules owned only by this packaging repository, add
`organization-overlay.md` beside the vendored file. Packaging composes it on a
temporary copy:

```text
secure-coding-baseline.md + organization-overlay.md = packaged baseline
```

The overlay must not declare another `baseline-id:`. It is never appended to
the tracked baseline file, so a later sync cannot erase organization prose.

## Organization Git mode

The organization repository owns derivation and composition: generic AISCB,
organization overlay, requirements, and approved values are combined there. It
must expose one ready-to-package document containing exactly one organization
baseline ID. This repository only consumes that result.

The generated Makefile records:

```make
BASELINE_SOURCE_KIND ?= organization-git
ORG_BASELINE_URL ?= git@github.com:acme/security-baseline.git
ORG_BASELINE_REF ?= main
ORG_BASELINE_SOURCE ?=
ORG_BASELINE_DOC ?= dist/claude-code/secure-coding-baseline.md
ORG_BASELINE_SKILLS_DIR ?= dist/claude-code/skills
```

Each check or sync temporarily fetches `ORG_BASELINE_REF` from
`ORG_BASELINE_URL`, materializes only the configured regular Git blobs, and
removes the temporary repository afterwards. It never checks out or executes
repository content. HTTPS Git URLs may not carry credentials; SSH uses the
caller's agent and Git configuration. Set `ORG_BASELINE_SOURCE` only as a
one-off existing-local-checkout override.

`ORG_BASELINE_DOC` and `ORG_BASELINE_SKILLS_DIR` are paths within the fetched
ref. They may not escape it; Git symlinks, submodules, special files, oversized
inputs, and skill packs without `SKILL.md` are rejected.

## Organization HTTPS mode

For a baseline published as one document:

```make
BASELINE_SOURCE_KIND ?= organization-https
ORG_BASELINE_URL ?= https://security.acme.example/baselines/secure-coding-baseline.md
ORG_BASELINE_REF ?=
ORG_BASELINE_SOURCE ?=
ORG_BASELINE_DOC ?=
ORG_BASELINE_SKILLS_DIR ?=
```

The URL must be HTTPS without embedded credentials, query, or fragment.
Redirects remain HTTPS-only. Sync downloads at most 1 MiB into temporary
storage, requires UTF-8 and exactly one `baseline-id:`, and then atomically
updates `baseline.file`. It does not discover adjacent files, unpack archives,
or accept skills.

Do not add `organization-overlay.md` here in an organization mode: the selected
document is already composed, and packaging rejects a second local overlay.

### Organization skills

Each direct child of `ORG_BASELINE_SKILLS_DIR` must be a valid skill directory
with `SKILL.md`. Sync copies it to `org-skills/<name>/` and records the managed
names in `.org-baseline-sync-state.json`. A later sync removes a
managed skill deleted from the source while preserving unrelated, manually
maintained `org-skills/` directories.

The same state records the fetched Git commit or HTTPS document digest as
provenance. It is not a lock: the next explicit sync follows the configured Git
ref or downloads the current HTTPS document, leaving the resulting tracked diff
for review.

Copying is not permission to ship. New skills remain excluded until their IDs
are explicitly added to `plugin_surface.skills.include` in
`org-profile/package-policy.yaml`; the sync prints a note for every missing
allowlist entry.

## Current generic copy

| File | ID | Source | Pinned at |
|---|---|---|---|
| `secure-coding-baseline.md` | `aiscb-0.1.10` | https://github.com/appsec-foundry/aiscb | tag `v0.1.10` |

SHA-256: `1d01542b50d29e649c56ba6d9ea896aa7988b9eb6af1b08f633cfa9d2361e5b6`.
