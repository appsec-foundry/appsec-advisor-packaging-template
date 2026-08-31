# Vendored secure-coding baselines

The file named by `baseline.file` in `org-profile/org-profile.yaml` travels with
the built package and is what `install-baseline` writes. It is the source, not a
fallback: the profile declares no `url`, so nothing is fetched at install time
and no machine installs rules that were never reviewed here.

Replace the file to ship your organization's own baseline. Any name works —
`baseline.file` decides which one is used, and `make validate` fails when the
file is missing or declares an id other than `baseline.id`.

## What is in here

| File | Id | Source | Pinned at | SHA-256 |
|---|---|---|---|---|
| `aiscb-0.1.10.md` | `aiscb-0.1.10` | https://github.com/appsec-foundry/aiscb | tag `v0.1.10` | `1d01542b50d29e649c56ba6d9ea896aa7988b9eb6af1b08f633cfa9d2361e5b6` |

A tag rather than a branch: a protected branch is not an immutable release, so
`main` gives a later reader nothing to compare against.

## Updating

`make baseline-check` reports when the check source publishes a newer release.
Updating is a reviewed change, not a fetch:

1. write the new document into this directory under its own id;
2. point `baseline.file` and `baseline.id` in the profile at it;
3. record the new row above and delete the row and file it replaces;
4. `make validate`, then raise `PACKAGE_VERSION` and rebuild.

The diff of step 1 is the point of the exercise — it is the last place anyone
reads the rules before they reach a developer machine.
