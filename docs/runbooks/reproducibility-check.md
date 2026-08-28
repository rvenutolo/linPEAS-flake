# Reproducibility Check Runbook

**Workflow:** [`.github/workflows/reproducibility-check.yml`](https://github.com/rvenutolo/linPEAS-flake/blob/main/.github/workflows/reproducibility-check.yml)
**Status:** Burn-in (non-blocking). Promotion criteria below.

## What this workflow does

On its weekly Friday cron (and on `workflow_dispatch`), the workflow:

1. Builds `.#linpeas` and `.#linpeas-image` twice on independent `ubuntu-latest` runners.
1. Records five values per build: linpeas store path, linpeas NAR hash, image store path, image tar SHA-256, and image manifest digest.
1. Compares the three hash values pairwise (`linpeas_nar_hash`, `image_tar_sha256`, `image_manifest_digest`); the two store paths are reported for context only and do not affect the result.
1. On any mismatch: runs `diffoscope` on both pairs (the image tars and the linpeas tarballs), each under its own 20-minute cap. The reports — `image.html`/`image.txt`, `linpeas.html`/`linpeas.txt` and `summary.txt` — are uploaded as the `repro-diff` artifact (30-day retention), and a GitHub issue labelled `reproducibility` is opened.

`diffoscope` is resolved from this repo's own flake — the compare job installs Nix through the `./.github/actions/setup-nix` composite and invokes `nix shell .#diffoscopeMinimal --command diffoscope`. The version that runs therefore tracks `flake.lock`, not whatever a distribution archive currently ships, and the job reaches only the hosts already in its `allowed-endpoints` list.

## How you'll be notified

During burn-in (`continue-on-error: true` on the compare job), workflow runs report green in the Actions UI even on mismatch — the primary alert channel is the auto-opened GitHub issue. If `gh issue create` itself fails, the step logs a `WARN` and the fallback signals are the `compare` job's own status and the `repro-diff` artifact.

To ensure mismatches are seen:

- The repo owner watches "All Activity" or "Issues" notifications on this repo, OR
- Add `--assignee` to the `gh issue create` invocation in the workflow once a maintainer wants direct paging.

Currently no `--assignee` is set; mismatches rely on default repo notification settings. Revisit after the first real mismatch (the runbook's "What to do when it fails" section assumes the responder has already seen the issue).

## What to do when it fails

1. Open the auto-created issue (label: `reproducibility`).
1. Follow the run link to the failed workflow run.
1. Download the `repro-diff` artifact.
1. Open `image.html` (or `linpeas.html`) in a browser.
1. Classify the divergence using the table below, then fix the root cause.

### Bad-input failures (exit 2)

`compare-repro.sh` exits 2 when a hash field is absent, null, or malformed in either build's `build.json`. That is not a divergence — the *measurement* broke.

- A `nix path-info --json` shape change is not the cause: both `measure` steps pipe it through `jq --exit-status` under `set -Eeuo pipefail`, so a shape change fails its own build job, and `compare` needs both builds and never runs.
- What *can* reach `compare` is a `build.json` that uploaded or downloaded incompletely.
- A `repro-diff` artifact is present on exit 2 — the diffoscope and upload steps gate on `exit_code != '0'`, which 2 satisfies — but it diffs builds whose measurement the compare script already rejected. Read the `build.json` files in the `repro-build-a` / `repro-build-b` artifacts instead.
- If a build job itself went red, triage its `measure` step there.

## Exercising the diagnostic path on demand

The diffoscope steps run only when the builds diverge, so on a reproducible tree they are never exercised and a break in them stays latent until the one day they are needed. `workflow_dispatch` carries a `force_diffoscope` input that runs them regardless:

```bash
gh workflow run reproducibility-check.yml --ref <ref> --field force_diffoscope=true
```

The input widens the `if:` on the diagnostic steps only — the diffoscope run and the `repro-diff` upload. `open issue (on mismatch)` and `fail job (on mismatch)` keep the mismatch-only condition, so a forced run can add execution but can never fabricate or suppress the reproducibility signal.

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
1. Run the workflow once manually via `workflow_dispatch` to confirm it still passes.
1. Add `compare` to the branch protection ruleset required-checks list (see [`docs/security/required-checks.md`](../security/required-checks.md) for the ruleset / required-checks edit flow).
1. Update this runbook's **Status** header to `Required`.
1. Commit changes on a single PR titled `ci: promote reproducibility check to required`.

## Demotion criteria

If a real-world repro break cannot be fixed within one week of detection:

1. Re-add `continue-on-error: true` to the `compare` job.
1. Remove `compare` from the ruleset required checks.
1. Update **Status** header to `Burn-in (demoted)`. Keep the date and the
    blocking issue number out of this file — `check-ephemeral-refs.sh` blocks
    both shapes in tracked prose. They belong in the demoting commit message
    and in the tracking issue.
1. Note under a `## Active demotions` section which check is demoted and what
    has to be true to re-promote it, linking the issue by title.
