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

## checkout-persist-credentials

Every `actions/checkout` step sets `with.persist-credentials: false` (boolean, not string).

Without it, `actions/checkout` writes `GITHUB_TOKEN` into `.git/config` and leaves it on disk for the remainder of the job. Any later step in the same job — a third-party action, a misbehaving binary, a shell injection in a `run:` block — can read the token from the working tree and use its scopes. `persist-credentials: false` drops the credential after the initial clone/fetch, narrowing the blast radius of a compromised later step.

Boolean `false` is required; the string `"false"` does not satisfy `actions/checkout`'s parsing.

Enforced by `scripts/check-checkout-persist-credentials.sh`. Wired as the `checkout-persist-credentials` required CI job and as a pre-commit hook.

## upload-artifact-strict

Every `actions/upload-artifact` step sets `with.if-no-files-found: error`.

The action's default is `warn`, which silently uploads an empty artifact when the `path:` glob matches nothing. That hides build-output drift: a broken path produces a green job with no artifact, and the consumer side only notices when something downstream goes missing — sometimes many runs later. `error` turns the path-mismatch into a hard upload failure, surfacing the bug at its source.

Enforced by `scripts/check-upload-artifact-strict.sh`. Wired as the `upload-artifact-strict` required CI job and as a pre-commit hook.

## workflow-on-branches

Every workflow that declares `on.pull_request:` or `on.push:` sets `branches: [main]` exactly under that trigger. No wildcards, no implicit all-branches, no other branch names.

Without the allowlist, Actions fires the workflow on every branch — burning runner minutes on stale topic branches and attaching surprising status checks to refs nobody is watching. Workflows that only run on `schedule:`, `workflow_dispatch:`, or `workflow_call:` are unaffected; `pull_request_target:` is handled by a separate lint that forbids it outright.

Enforced by `scripts/check-workflow-on-branches.sh`. Wired as the `workflow-on-branches` required CI job and as a pre-commit hook.

## pull-request-target-absent

No workflow uses the `pull_request_target` trigger.

`pull_request_target` runs the **base** ref's workflow definition with the full secret scope of the base repo. If the workflow then checks out the PR head (the common reason to use this trigger), an attacker's fork PR can introduce malicious code that the base-ref workflow runs with secret access — the canonical Actions privilege-escalation footgun.

This repo has no use for the trigger. The lint hard-fails any workflow that adopts it. Removing the ban requires deleting this script and the corresponding required-check entry.

Enforced by `scripts/check-pull-request-target-absent.sh`. Wired as the `pull-request-target-absent` required CI job and as a pre-commit hook.

## script-shebang-pipefail

Every file under `scripts/*.sh` starts with `#!/usr/bin/env bash` (exact first line) and contains `set -Eeuo pipefail` somewhere in the file.

A script that silently swallows a failure can corrupt `linpeas-pin.json`, skip a security check, or leave a stale build artifact behind. `set -Eeuo pipefail` plus a portable shebang are the hardening minimum: `-e` aborts on any command failure, `-E` propagates ERR traps into subshells, `-u` rejects unset variables, `-o pipefail` makes a pipeline fail when any stage fails (not just the last).

The lint accepts longer set lines (e.g. `set -Eeuo pipefail -x`) as long as the exact `-Eeuo pipefail` token is present.

Enforced by `scripts/check-script-shebang-pipefail.sh`. Wired as the `script-shebang-pipefail` required CI job and as a pre-commit hook.

## script-has-test

Every `scripts/check-*.sh` has a matching `tests/check-*.test.sh`, and every `tests/check-*.test.sh` has a matching `scripts/check-*.sh`.

The check-lint family is held together by naming convention: each lint script ships next to a fixture-driven test harness that validates the script's spec. Without enforcement, a new lint can land without tests and silently rot. The bidirectional pairing forecloses that.

`check-jsonschema` is exempt: it's a thin wrapper around the upstream `check-jsonschema` tool plus a schema bundle, so there's no spec-driven behavior worth unit-testing. New exemptions require updating the `EXEMPT` list in the script and justifying the entry in its comment.

Enforced by `scripts/check-script-has-test.sh`. Wired as the `script-has-test` required CI job and as a pre-commit hook.

## ci-job-in-summary

Every `jobs.<name>:` in `.github/workflows/ci.yml` either appears as a key in `docs/_data/ci-check-categories.yml` or is on the lint's `EXEMPT` list of auxiliary jobs (sandbox harnesses, notify-only jobs, matrix expansions). Conversely, every key in the category map corresponds to a real `jobs.<name>:` in some workflow file under `.github/workflows/`.

`refresh-ci-summary.sh` already enforces parity between the category map and `docs/security/required-checks.md`. This lint adds the ci.yml ↔ categories check, so a new required job that ships without a category mapping fails the PR rather than landing and breaking the pre-commit summary regenerator on the next commit.

Adding a new ci.yml job that should be a required status check requires updating the categories map, the required-checks doc, and the protect-main ruleset (in-tree and live). Adding an auxiliary job requires only an `EXEMPT` entry justified in the script comment.

Enforced by `scripts/check-ci-job-in-summary.sh`. Wired as the `ci-job-in-summary` required CI job and as a pre-commit hook.

## run-block-strict

Every multi-line `run:` block under `.github/workflows/*.yml` starts with `set -Eeuo pipefail` as its first non-blank, non-comment line.

Bash inside Actions `run:` blocks defaults to `-e` off. A failed command in the middle of a multi-line block silently continues, producing wrong results in security-critical jobs (release signing, attestation verify, pin write-back). The strict-mode prelude closes that gap.

Single-line `run:` invocations are exempt — they're already a single shell command whose exit status drives the step directly.

Enforced by `scripts/check-run-block-strict.sh`. Wired as the `run-block-strict` required CI job and as a pre-commit hook.

## fork-guard-release

Every workflow job that holds release-grade GITHUB_TOKEN scope includes a fork-guard `if:` clause containing `github.repository == 'rvenutolo/linPEAS-flake'`.

Release-grade scopes are any of: `contents: write`, `packages: write`, `id-token: write`, `attestations: write`. A fork that inherits these workflows can otherwise fire them under its own `GITHUB_TOKEN` (or repo-scoped secrets, if any were configured) — accidentally cutting a release, pushing to the fork's container registry, or minting OIDC tokens. The repository check pins execution to the canonical repo.

GitHub Actions `if:` is job-scoped (no workflow-level syntax), so every release-grade job must carry the guard in its own `if:` expression. Existing `if:` clauses are AND-ed with the repository check.

Enforced by `scripts/check-fork-guard-release.sh`. Wired as the `fork-guard-release` required CI job and as a pre-commit hook.
