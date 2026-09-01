# Organization Skills

Put organization-owned Claude Code plugin skills here when they should ship with
the internal package next to the upstream `appsec-advisor` skills.

Each skill gets its own directory:

```text
org-skills/
└── myorg-architecture-review/
    └── SKILL.md
```

Rules:

- Use a new skill name. A local skill must not overwrite an upstream skill.
- Keep names lowercase: letters, digits, `.`, `_`, and `-` are allowed.
- Add the skill name to `org-profile/package-policy.yaml` when `skills.include`
  is used. That allowlist controls both upstream and organization skills.

During `make package`, these skills are copied into a temporary upstream source
tree before the upstream packager runs. The upstream checkout under `upstream/`
is not modified.

When `BASELINE_SOURCE_KIND=organization-git`, `make baseline-sync` may also
manage skills materialized from `ORG_BASELINE_SKILLS_DIR` at the configured Git
URL/ref. Managed names are recorded in the repository-root
`.org-baseline-sync-state.json`, so later source removals do not delete unrelated
manual skills. HTTPS mode accepts no skills. A synced skill still needs an
explicit `plugin_surface.skills.include` entry before it ships.
