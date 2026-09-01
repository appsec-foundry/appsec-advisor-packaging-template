# Baselines

This folder holds the secure-coding baseline that ships with the package.
`baseline.file` in `org-profile/org-profile.yaml` picks the file, `baseline.url`
says where an install fetches from.

The copy here is not a nice-to-have. It is what gets installed whenever the URL
cannot be reached or has moved on to a newer version, and without it an install
simply fails.

The file name stays the same across versions. The version lives in the
document's own `baseline-id:` line and in `baseline.id` in the profile, so an
update shows up as a diff on one file instead of a delete and an add.

| File | Id | Source | Pinned at |
|---|---|---|---|
| `secure-coding-baseline.md` | `aiscb-0.1.10` | https://github.com/appsec-foundry/aiscb | tag `v0.1.10` |

SHA-256: `1d01542b50d29e649c56ba6d9ea896aa7988b9eb6af1b08f633cfa9d2361e5b6`.
Pinned to a tag rather than a branch, so there is something fixed to compare
against later.

## Adding your own rules

Add an `organization-overlay.md` file next to the baseline file. If it exists,
`make package` appends it to the baseline before the package is built:

```
secure-coding-baseline.md  +  organization-overlay.md  =  shipped baseline
```

Nothing here is written back to `secure-coding-baseline.md` itself — the
composition happens on a throwaway copy, so `git status` stays clean and
`make baseline-sync` (which re-vendors the base file from its source) can
never overwrite your rules by clobbering the same file they lived in. This
replaces the old convention of appending rules directly into the baseline
file and renaming its id to `<base-id>+<suffix>`: that worked, but an
unattended sync silently destroyed the appended text because it lived in the
file sync overwrites.

The overlay is plain prose that extends the base rules — it must not add its
own `baseline-id:` line. The id stays owned by the base file and
`baseline.id` in the profile; a composed document with two id markers fails
the build with a clear error instead of shipping two competing rule sets.
Leave `baseline.id`/`baseline.url` pointed at the base document; they are what
`make baseline-check` watches for upstream updates, unaffected by the overlay.

Want your own version tag on the overlay anyway? Use any label except
`baseline-id:`, for example `` `KN overlay version: knscb-0.1.0` ``. It stays
plain text, so the assistant still reads it and can tell a developer which
version is active when asked.

Want it visible without asking — right in the packaged README or session
status? Set `baseline.name` in `org-profile.yaml` instead, for example
`name: "AI Secure Coding Baseline + KN overlay knscb-0.1.0"`. That field is
just a display label; nothing checks it against anything.

Either way, leave `baseline.id` alone. `make baseline-check` compares it,
character for character, against the live document at `baseline.url` —
change it and the check reports false drift forever.

### Skills that belong to the baseline

An overlay can also declare organization-specific skills, not just prose —
for example a rule that tells the assistant to load a particular reference
pack before touching a certain kind of code. Nothing new is needed to package
one: put it under `org-skills/<name>/` like any other org skill (any
supporting files next to `SKILL.md` — reference packs, blueprint configs, a
locally cached snapshot — are packaged along with it), and add its name to
`plugin_surface.skills.include` in `org-profile/package-policy.yaml` as
usual.

## Updating

`make baseline-check` tells you when a newer version of the base document has
been published. Updating is a review, not a download:

1. write the new document over `secure-coding-baseline.md`
2. set `baseline.id` in the profile to the version it declares
3. update the table above
4. run `make validate`, raise `PACKAGE_VERSION`, rebuild

Read the diff in step 1. It is the last time anyone sees these rules before
they reach a developer's machine. `organization-overlay.md`, if you have one,
needs no attention here — it is not touched by the sync.
