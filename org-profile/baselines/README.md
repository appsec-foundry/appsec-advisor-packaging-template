# Vendored secure-coding baselines

The file named by `baseline.file` in `org-profile/org-profile.yaml` travels with
the built package. `baseline.url` is what an install fetches; this copy is what
it writes when that URL is unreachable or has moved on to a newer id. Without it
an install fails outright in both cases, in every package already distributed.

Replace the file to ship your organization's own baseline. Any name works —
`baseline.file` decides which one is used, and `make validate` fails when the
file is missing or declares an id other than `baseline.id`.

## What is in here

| File | Id | Source | Pinned at | SHA-256 |
|---|---|---|---|---|
| `aiscb-0.1.10.md` | `aiscb-0.1.10` | https://github.com/appsec-foundry/aiscb | tag `v0.1.10` | `1d01542b50d29e649c56ba6d9ea896aa7988b9eb6af1b08f633cfa9d2361e5b6` |

A tag rather than a branch: a protected branch is not an immutable release, so
`main` gives a later reader nothing to compare against.

## Adding your own rules

One file, one id. The plugin installs a single baseline file and wires a single
import, so an overlay is your rules appended to the baseline text rather than a
second document beside it. Mark the result as a derivative by changing the one
`baseline-id:` line to `<base>+<org>`, for example `aiscb-0.1.10+acme`: it
counts as installed and is reported with its suffix, so a reader sees the
adaptation.

```
AI Secure Coding Baseline · aiscb-0.1.10+acme · this machine
```

Three things to get right:

- Leave `baseline.id` on the base id. `make baseline-check` compares it with the
  published document exactly, so `aiscb-0.1.10+acme` there reports drift forever.
  The file carries the suffix; the profile keeps naming what it was derived from.
- Keep one `baseline-id:` line. Two — the baseline's and your overlay's — read as
  a second, foreign baseline loaded beside the configured one, and the session
  status says `also acme-sec-1.0.0 in this machine` in every session.
- Point `baseline.url` at your own document, or drop it. Left on the upstream
  source, `make baseline-sync` overwrites your combined file with the plain
  upstream text, and the id check does not stop it because a derivative matches.

## Updating

`make baseline-check` reports when the check source publishes a newer release.
Updating is a reviewed change, not a fetch:

1. write the new document into this directory under its own id;
2. point `baseline.file` and `baseline.id` in the profile at it;
3. record the new row above and delete the row and file it replaces;
4. `make validate`, then raise `PACKAGE_VERSION` and rebuild.

The diff of step 1 is the point of the exercise — it is the last place anyone
reads the rules before they reach a developer machine.
