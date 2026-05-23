# Workflow-hardening invariants

Per-job hardening rules enforced across every workflow in `.github/workflows/`. Each rule is locked in by a script lint, wired as a required CI job and as a pre-commit hook.

## job-timeout-minutes

Every job declares an explicit `timeout-minutes` as a positive integer.

GitHub Actions defaults a job timeout to 6 hours. A hung job at that ceiling burns the runner budget and stalls the merge queue. Requiring an explicit per-job value bounds the blast radius of any wedge and forces a deliberate choice when a job is added.

Reusable-workflow callers (jobs that use `uses: ./.github/workflows/<file>.yml`) are exempt because `timeout-minutes` is not valid on that shape; the timeout belongs in the called workflow's jobs.

Enforced by `scripts/check-job-timeout-minutes.sh`. Wired as the `job-timeout-minutes` required CI job and as a pre-commit hook.

## workflow-concurrency

Every workflow declares a top-level `concurrency:` block with a non-empty `group:`.

Without a concurrency group, cron pile-ups and back-to-back PR pushes can spawn parallel runs on the same ref. Beyond burning runner minutes on superseded work, parallel runs can race steps that touch shared remote state (`gh release create`, tag pushes, image manifest writes). Forcing every workflow to declare a group keeps each ref serialized to one in-flight run by default.

`cancel-in-progress` is not required by this lint; the group alone is the load-bearing setting. Pipelines that must run to completion once started (e.g., `release-on-bump.yml`) deliberately set `cancel-in-progress: false` so back-to-back triggers queue instead of cancelling.

Enforced by `scripts/check-workflow-concurrency.sh`. Wired as the `workflow-concurrency` required CI job and as a pre-commit hook.
