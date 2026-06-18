# Reproducibility Check Runbook

**Workflow:** [`.github/workflows/reproducibility-check.yml`](https://github.com/rvenutolo/linPEAS-flake/blob/main/.github/workflows/reproducibility-check.yml)
**Status:** Burn-in (non-blocking). Promotion criteria below.

## What this workflow does

Every Friday at 05:10 UTC (and on `workflow_dispatch`), the workflow:

1. Builds `.#linpeas` and `.#linpeas-image` twice on independent `ubuntu-latest` runners.
1. Records each build's: linpeas store path, linpeas NAR hash, image store path, image tar SHA-256, image manifest digest.
1. Compares the five values pairwise.
1. On any mismatch: installs `diffoscope`, runs it against the differing artifacts with a 20-minute cap, uploads `diffoscope.html` and `diffoscope.txt` as the `repro-diff` artifact (30-day retention), and opens a GitHub issue labelled `reproducibility`.

## How you'll be notified

During burn-in (`continue-on-error: true` on the compare job), workflow runs report green in the Actions UI even on mismatch — the only alert channel is the auto-opened GitHub issue.

To ensure mismatches are seen:

- The repo owner watches "All Activity" or "Issues" notifications on this repo, OR
- Add `--assignee` to the `gh issue create` invocation in the workflow once a maintainer wants direct paging.

Currently no `--assignee` is set; mismatches rely on default repo notification settings. Revisit after the first real mismatch (the runbook's "What to do when it fails" section assumes the responder has already seen the issue).

## What to do when it fails

1. Open the auto-created issue (label: `reproducibility`).
1. Follow the run link to the failed workflow run.
1. Download the `repro-diff` artifact.
1. Open `diffoscope.html` in a browser.
1. Classify the divergence using the table below, then fix the root cause.

## Common nondeterminism sources

| Symptom in diffoscope                      | Likely cause                   | Fix                                                                                          |
| ------------------------------------------ | ------------------------------ | -------------------------------------------------------------------------------------------- |
| Embedded timestamp differs                 | Build-time `date` leaking in   | Set `SOURCE_DATE_EPOCH` in derivation; use `nix-store --query --references` to find offender |
| Go binary differs in `.note.go.buildid`    | `-buildid` flag default        | Pass `-ldflags '-buildid='`                                                                  |
| Rust binary differs in debug section       | Source path leakage            | Set `RUSTFLAGS=--remap-path-prefix=...`                                                      |
| Locale-dependent sort order in text output | `LC_ALL` unset                 | Set `LC_ALL=C` in derivation                                                                 |
| Embedded `$PWD` / build directory          | nixpkgs `stripAllList` skipped | Add to `stripAllList` or use `removeReferencesTo`                                            |
| Parallel-build ordering in archives        | tar without `--sort=name`      | Use `tar --sort=name --owner=0 --group=0 --mtime='@${SOURCE_DATE_EPOCH}'`                    |

## Promotion criteria

Promote the `compare` job to a required check once **all** are true:

- 4 consecutive green weekly runs with no manual workarounds
- No outstanding `reproducibility`-labelled issues
- Image build time at parity with baseline (no diagnostic overhead left in workflow)

Promotion steps:

1. Edit `.github/workflows/reproducibility-check.yml`: remove `continue-on-error: true` from the `compare` job.
1. Run the workflow once manually via `workflow_dispatch` to confirm it still passes.
1. Add `Reproducibility Check / compare` to the branch protection ruleset required-checks list (see [`docs/security/required-checks.md`](../security/required-checks.md) for ruleset edit flow).
1. Update this runbook's **Status** header to `Required`.
1. Commit changes on a single PR titled `ci: promote reproducibility check to required`.

## Demotion criteria

If a real-world repro break cannot be fixed within one week of detection:

1. Re-add `continue-on-error: true` to the `compare` job.
1. Remove `Reproducibility Check / compare` from the ruleset required checks.
1. Update **Status** header to `Burn-in (demoted YYYY-MM-DD pending issue #N)`.
1. Link the blocking issue here under a `## Active demotions` section.
