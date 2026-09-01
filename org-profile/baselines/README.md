# Baselines

This folder holds the reviewed secure-coding baseline shipped by the package.
`baseline.file` in `org-profile/org-profile.yaml` is authoritative: every sync
reads and writes that file, and packaging fails when its `baseline-id:` differs
from `baseline.id`.

The initializer persists one source mode in the Makefile:

- `aiscb`: vendor the generic [AI Secure Coding Baseline](https://github.com/appsec-foundry/aiscb).
- `organization`: copy a composed baseline and optional skill packs from a
  separately checked-out local organization repository.
- `disabled`: keep baseline installation disabled.

The same commands work for both enabled modes:

```bash
make baseline-sync-check       # read-only: exit 0 current, 1 drift, 2 error
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

## Organization repository mode

The organization repository owns derivation and composition: generic AISCB,
organization overlay, requirements, and approved values are combined there. It
must expose one ready-to-package document containing exactly one organization
baseline ID. This repository only consumes that result.

The generated Makefile records:

```make
BASELINE_SOURCE_KIND ?= organization
ORG_BASELINE_SOURCE ?= ../acme-aiscb
ORG_BASELINE_DOC ?= dist/claude-code/secure-coding-baseline.md
ORG_BASELINE_SKILLS_DIR ?= dist/claude-code/skills
```

`ORG_BASELINE_SOURCE` is local by design. CI checks out the organization
repository separately and supplies the same path; the sync target never clones
or pulls a moving branch. `ORG_BASELINE_DOC` and `ORG_BASELINE_SKILLS_DIR` are
relative to that source and may not escape it or traverse symlinks.

Do not add `organization-overlay.md` here in organization mode: the selected
document is already composed, and packaging rejects a second local overlay.

### Organization skills

Each direct child of `ORG_BASELINE_SKILLS_DIR` must be a valid skill directory
with `SKILL.md`. Sync copies it to `org-skills/<name>/` and records the managed
names in `.org-baseline-sync-state.json`. A later sync removes a
managed skill deleted from the source while preserving unrelated, manually
maintained `org-skills/` directories.

Copying is not permission to ship. New skills remain excluded until their IDs
are explicitly added to `plugin_surface.skills.include` in
`org-profile/package-policy.yaml`; the sync prints a note for every missing
allowlist entry.

## Current generic copy

| File | ID | Source | Pinned at |
|---|---|---|---|
| `secure-coding-baseline.md` | `aiscb-0.1.10` | https://github.com/appsec-foundry/aiscb | tag `v0.1.10` |

SHA-256: `1d01542b50d29e649c56ba6d9ea896aa7988b9eb6af1b08f633cfa9d2361e5b6`.
