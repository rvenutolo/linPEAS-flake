# Reproducibility check runbook

**Workflow:** [`.github/workflows/reproducibility-check.yml`](https://github.com/rvenutolo/linPEAS-flake/blob/main/.github/workflows/reproducibility-check.yml)
**Status:** Burn-in (non-blocking). Promotion criteria below. This
header is maintained by hand — no check compares it against the
workflow, so the promotion and demotion checklists each carry a step updating
it.

## What this workflow does

On its weekly Friday cron (and on `workflow_dispatch`), the workflow:

1. Builds `.#linpeas` and `.#linpeas-image` twice on independent `ubuntu-latest` runners.
1. Records five values per build: linpeas store path, linpeas NAR hash, image store path, image tar SHA-256, and image manifest digest.
1. Compares the three hash values pairwise (`linpeas_nar_hash`, `image_tar_sha256`, `image_manifest_digest`); the two store paths are reported for context only and do not affect the result.
1. On any nonzero compare result — a hash mismatch or an exit-2 measurement failure: runs `diffoscope` on both pairs (the image tars and the linpeas tarballs), each under its own 20-minute cap. The reports — `image.html`/`image.txt`, `linpeas.html`/`linpeas.txt` and `summary.txt` — are uploaded as the `repro-diff` artifact (30-day retention), a GitHub issue labelled `reproducibility` is opened, and the `compare` job is failed by its `fail job (on mismatch)` step.

`diffoscope` is resolved from this repo's own flake — the compare job installs Nix through the `./.github/actions/setup-nix` composite and invokes `nix shell .#diffoscopeMinimal --command diffoscope`. The version that runs therefore tracks `flake.lock`, not whatever a distribution archive currently ships, and the job reaches only the hosts already in its `allowed-endpoints` list.

## How you'll be notified

During burn-in (`continue-on-error: true` on the compare job), workflow runs report green in the Actions UI even on mismatch — the primary alert channel is the auto-opened GitHub issue. If `gh issue create` itself fails, the step logs a `WARN` and the fallback signals are the `compare` job's own status and the `repro-diff` artifact.

To ensure mismatches are seen, the repo owner watches "All Activity" or "Issues" notifications on this repo.

The `gh issue create` invocation sets no `--assignee`; mismatches rely on default repo notification settings. Add `--assignee` to that invocation once a maintainer wants direct paging, and revisit after the first real mismatch (the runbook's "What to do when it fails" section assumes the responder has already seen the issue).

## What to do when it fails

1. Open the auto-created issue (label: `reproducibility`).
1. Follow the run link to the failed workflow run.
1. Download the `repro-diff` artifact.
1. Open `image.html` (or `linpeas.html`) in a browser.
1. Classify the divergence using the table below, then fix the root cause.

### Bad-input failures (exit 2)

`compare-repro.sh` exits 2 when a hash field is absent, null, or malformed in either build's `build.json` — and likewise when it is called with the wrong argument count, `jq` is not on `PATH`, an input file is missing, or a payload is not a JSON object. None of those is a divergence — the *measurement* broke.

- A `nix path-info --json` shape change is not the cause: both `measure hashes` steps pipe it through `jq --exit-status` under `set -Eeuo pipefail`, so a shape change fails its own build job, and `compare` needs both builds and never runs.
- What *can* reach `compare` is a `build.json` that uploaded or downloaded incompletely.
- A `repro-diff` artifact is present on exit 2 — the diffoscope and upload steps gate on `exit_code != '0'`, which 2 satisfies — but it diffs builds whose measurement the compare script already rejected. Read the `build.json` files in the `repro-build-a` / `repro-build-b` artifacts instead; those expire after 7 days (vs `repro-diff`'s 30), so exit-2 triage has a one-week window.
- The `open issue (on mismatch)` and `fail job (on mismatch)` steps gate on the same `exit_code != '0'` condition, so exit 2 also files an issue and fails the job — and the issue body's "detected a mismatch" wording is not to be trusted until the `compare hashes` step's exit code is checked.
- If a build job itself went red, triage its `measure hashes` step there.

## Exercising the diagnostic path on demand

The diffoscope step and the `repro-diff` upload run only when the builds diverge, so on a reproducible tree they are never exercised and a break in them stays latent until the one day they are needed. `workflow_dispatch` carries a `force_diffoscope` input that runs them regardless:

```bash
gh workflow run reproducibility-check.yml --ref <ref> --field force_diffoscope=true
```

The input widens the `if:` on the diagnostic steps only — the diffoscope run and the `repro-diff` upload. `open issue (on mismatch)` and `fail job (on mismatch)` keep the compare-nonzero condition unwidened by `force_diffoscope`, so a forced run can add execution but can never fabricate or suppress the reproducibility signal.

A healthy forced run on a reproducible tree looks like this:

1. `setup-nix` completes — no harden-runner block annotation, no fetch failure.
1. The diffoscope step runs both comparisons (the image tars, then the linpeas tarballs).
1. The `repro-diff` artifact uploads.
1. **No issue is filed and the `compare` job does not fail.**

Any of the first three missing means the diagnostic path is broken; a failing job or a filed issue means the forced run also found a genuine mismatch, which is triaged as above.

### Reading `summary.txt`

The `repro-diff` artifact always carries `summary.txt`, one line per compared pair, naming that pair's `diffoscope` exit status and whether a report was written:

```text
image: diffoscope exit 0, report none
linpeas: diffoscope exit 0, report none
```

`diffoscope` exits 0 and writes no report when its two inputs are identical, so `exit 0, report none` on both lines is the expected outcome of a forced run on a reproducible tree — that is the diagnostic working, not failing. A diverging pair reports a non-zero exit with `report written`, and its `image.html` / `linpeas.html` are the files to open.

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

- 4 consecutive weekly runs in which the `compare` job's
    `fail job (on mismatch)` step did not fire — workflow-level green is
    not the signal, since `continue-on-error` masks a mismatch
- No outstanding `reproducibility`-labelled issues
- Image build time at parity with baseline (no diagnostic overhead left in workflow)

Promotion steps:

1. Edit `.github/workflows/reproducibility-check.yml`: remove `continue-on-error: true` from the `compare` job.
1. Add a `pull_request:` trigger targeting `main` to the same workflow, with no `paths:` / `paths-ignore:` filter (`scripts/check-required-checks-no-paths.sh` rejects a path filter on any workflow listed in [`docs/security/required-checks.md`](../security/required-checks.md), so it starts enforcing this once step 4 lands). The workflow currently runs only on its weekly cron and `workflow_dispatch`; a required status context whose workflow never runs on pull requests leaves every PR waiting for a report that never arrives.
1. Push the branch, then dispatch against it: `gh workflow run reproducibility-check.yml --ref <promotion-branch>`. The `--ref` is load-bearing: a bare `gh workflow run reproducibility-check.yml` targets `main`, whose copy still carries `continue-on-error: true`, so it confirms nothing about the change. Confirm the run is green, then confirm the change itself by re-reading the dispatched ref's workflow file (`gh api repos/rvenutolo/linPEAS-flake/contents/.github/workflows/reproducibility-check.yml?ref=<promotion-branch>`): the `compare` job must carry no `continue-on-error`. There is no runtime signal on a clean tree — a matching build gives the flag nothing to mask.
1. Update `.github/rulesets/protect-main.json`, the required-contexts table in [`docs/security/required-checks.md`](../security/required-checks.md), and `docs/_data/ci-check-categories.yml` in the same change, and run `just show-ci-summary` to regenerate the README summary block (the CI-summary freshness gate fails otherwise; see that page for the edit flow).
1. Update this runbook's **Status** header to `Required`.
1. Add `compare` to the **live** ruleset, before opening the PR.
    `.github/rulesets/protect-main.json` is only the in-tree mirror:
    `scripts/check-protect-main.sh` fetches the live ruleset and diffs it
    against that file, so a PR carrying the mirror edit alone holds
    `protect-main-drift-check` red until the live `PUT` lands. Land other open
    PRs first — rebasing will not help them, since `main` carries neither the
    mirror edit nor the `pull_request:` trigger until this PR merges. Between
    the `PUT` and that merge, `main` and every open PR without the mirror edit
    fail `protect-main-drift-check` as well as waiting on a `compare` context
    that never reports. The promotion PR itself is unaffected: its own head
    carries both.
1. Commit changes on a single PR titled `ci: promote reproducibility check to required`. `protect-main-drift-check` goes green once the live `PUT` from the previous step is in place, at which point the PR can merge.

## Demotion criteria

If a real-world repro break cannot be fixed within one week of detection:

1. Re-add `continue-on-error: true` to the `compare` job.
1. Drop `compare` from the **live** ruleset first, as promotion added it
    first — that immediately stops `compare` gating every open PR. Until the
    demotion PR merges, `main` and every open PR whose mirror still lists
    `compare` fail `protect-main-drift-check`; the demotion PR's own head is
    green, because it carries the mirror edit.
1. Remove `compare` from `.github/rulesets/protect-main.json`, the
    required-contexts table in
    [`docs/security/required-checks.md`](../security/required-checks.md), and
    `docs/_data/ci-check-categories.yml`, and run `just show-ci-summary` to
    regenerate the README summary block (the same gates that guard promotion
    fail otherwise).
1. Remove the `pull_request:` trigger added at promotion — a demoted,
    non-required check has no reason to run on every PR. This rides in the
    same PR as the previous step; the ordering that matters is the live
    `PUT`, not the order of edits inside one merge.
1. Update **Status** header to `Burn-in (demoted)`. Keep the date and the
    blocking issue number out of this file — `check-ephemeral-refs.sh` blocks
    both shapes in tracked prose. They belong in the demoting commit message
    and in the tracking issue.
1. Note under a `## Active demotions` section which check is demoted and what
    has to be true to re-promote it, linking the issue by title.
1. Commit changes on a single PR titled
    `ci: demote reproducibility check from required`, then confirm the
    demotion took: open a throwaway PR and check that `compare` no longer
    appears in its check list.
