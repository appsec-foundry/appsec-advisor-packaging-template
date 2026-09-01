# Organization baseline source modes

Status: implemented in the packaging template.

## Decision

Generated packaging repositories select one secure-coding baseline source:

1. `aiscb`: the generic baseline published by `appsec-foundry/aiscb`.
2. `organization`: a composed organization baseline from a separately checked
   out local repository, with optional organization skill packs.
3. `disabled`: no baseline installation.

The initializer writes the selected mode and its source settings into the
generated Makefile. Reinitialization preserves them. Maintainers use the same
`make baseline-sync` and `make baseline-sync-check` interface in either enabled
mode.

## Ownership boundary

The organization baseline repository owns:

- the generic AISCB input it derives from;
- organization overlays and approved values;
- composition into one document with one organization `baseline-id:`;
- optional Claude Code skill packs exposed as child directories containing
  `SKILL.md`.

The packaging repository owns:

- the reviewed copy selected by `baseline.file`;
- the matching `baseline.id` in `org-profile.yaml`;
- copied organization skills and the explicit package allowlist;
- drift checks, review, package versioning, and release.

The organization source is local by design. CI checks it out independently and
provides the configured path. The sync command does not clone, pull, or execute
content from a moving remote ref.

## Sync behavior

`make baseline-sync-check` returns 0 when current, 1 for drift, and 2 for an
invalid or unavailable source. `make baseline-sync` applies same-ID changes. A
new ID exits 3 until the maintainer supplies the exact published ID through
`ACCEPT_ID=<id>`; the accepted change updates document and profile together.

Organization document and skill paths must remain inside the selected source.
Symlinked source content and symlinked destinations are rejected. Skill trees
are compared by content rather than timestamps. A tracked sync-state file names
only skills managed by the organization source, allowing removed managed skills
to be deleted without touching manually maintained `org-skills/` entries.

Copying a skill does not authorize it for packaging. New skill IDs remain out
of the built plugin until a maintainer explicitly adds them to
`plugin_surface.skills.include`.

## Overlay rule

In generic AISCB mode, a packaging repository may keep a local
`org-profile/baselines/organization-overlay.md`; packaging composes it on a
temporary copy.

In organization mode, the selected source document is already composed. A
second packaging-repository overlay is rejected so central rules cannot be
duplicated or diverge from the organization artifact.
