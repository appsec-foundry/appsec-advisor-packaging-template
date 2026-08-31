# Baselines

This folder holds the secure-coding baseline that ships with the package.
`baseline.file` in `org-profile/org-profile.yaml` picks the file, `baseline.url`
says where an install fetches from.

The copy here is not a nice-to-have. It is what gets installed whenever the URL
cannot be reached or has moved on to a newer version, and without it an install
simply fails.

| File | Id | Source | Pinned at |
|---|---|---|---|
| `aiscb-0.1.10.md` | `aiscb-0.1.10` | https://github.com/appsec-foundry/aiscb | tag `v0.1.10` |

SHA-256: `1d01542b50d29e649c56ba6d9ea896aa7988b9eb6af1b08f633cfa9d2361e5b6`.
Pinned to a tag rather than a branch, so there is something fixed to compare
against later.

## Shipping your own rules

Write them into the baseline file and change its `baseline-id:` line to
`aiscb-0.1.10+acme`. The suffix says these are your rules on top of that
version, and the session status shows it:

```
AI Secure Coding Baseline · aiscb-0.1.10+acme · this machine
```

Keep it to one `baseline-id:` line. Two of them look like two competing rule
sets, and every session will complain about it.

In the profile, leave `baseline.id` as `aiscb-0.1.10`, without the suffix. That
is the version `make baseline-check` watches for updates.

Point `baseline.url` at your own copy, or remove it. If it still points
upstream, `make baseline-sync` replaces your file with the original text.

## Updating

`make baseline-check` tells you when a newer version has been published.
Updating is a review, not a download:

1. put the new document in this folder, named after its id
2. point `baseline.file` and `baseline.id` at it
3. update the table above, delete the file it replaces
4. run `make validate`, raise `PACKAGE_VERSION`, rebuild

Read the diff in step 1. It is the last time anyone sees these rules before
they reach a developer's machine.
