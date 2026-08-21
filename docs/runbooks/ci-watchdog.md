# Runbook: CI retry watchdog

## What it does

`ci-watchdog` runs on a cron schedule
(see [CI — cron schedule](../architecture/ci.md#cron-schedule)). It finds
open bot-authored pull requests that have auto-merge enabled and a failed
workflow run on their current head commit, and re-runs the failed jobs.

Each run gets at most 3 attempts. `reRunWorkflowFailedJobs` re-runs a run in
place and increments its attempt counter, so the bound needs no stored
state — and a new commit resets it, because a new commit produces a new run
at attempt 1.

Separately from that 3-attempt run bound, the watchdog's own API requests
retry on a 5xx. Rate limits, conflicts, already-exists responses, and
malformed, unauthorized, or missing-resource requests are exempt — they do not
become valid on a second try.

An error that survives that retry is confined to the PR it happened on. The
sweep processes every remaining PR and then fails the job, naming the PRs
that errored. The one exception is a rate limit: continuing to request
against an exhausted budget can make it worse, so the sweep halts instead
and fails the job naming both the PRs that errored and the PRs it left
untried. Either way, no PR is starved silently, and no error is swallowed
except `createLabel`'s 422 when the escalation label already exists.

The watchdog re-runs **any** failure, without trying to classify it as
transient. Classification would need a hand-maintained list of failure
signatures, and such lists rot silently. It also could not work here:
`connection refused` is both the signature of a CDN blip and the signature
of a harden-runner egress block, which is a permanent configuration bug.

## Why it exists

Nothing else in this repo re-runs a failed job. A bot PR with auto-merge
enabled that hits a transient infrastructure failure will sit open forever,
because auto-merge waits for checks that will never re-run. This has parked
bump PRs for weeks at a time.

## When you get a `ci-watchdog: PR #N exhausted retries` issue

The watchdog exhausted the PR's 3-attempt budget — the original run plus 2
re-runs — and the jobs failed every time. That is no longer a transient —
treat it as a real failure.

1. Open the run URLs listed in the issue body and read the failing job's log.
1. If the PR is genuinely broken (a dependency bump that breaks the build, a
    lint that genuinely fires), fix it or close the PR. The watchdog will not
    touch it again unless a new commit resets the attempt counter.
1. If it is a real infrastructure failure that outlasted 3 retries (a
    multi-hour upstream outage), re-run manually once the outage clears:
    `gh run rerun <run-id> --failed`.
1. If the failure is a harden-runner egress block — a `connection refused`
    or `ECONNREFUSED` against a healthy public host — the allowlist is
    missing a host. Add it and check whether `check-egress-allowlist.sh`
    should have caught it; if it should have, the lint has a gap worth
    closing.

Close the issue once the PR merges or is closed.

The watchdog files ONE issue per stuck PR and comments on it only when a
later tick observed something the last report did not — a different head
commit, or a different set of exhausted runs. A run of ticks that sees the
same thing stays silent, so the issue's comment thread is a list of changes,
not a heartbeat: if it has not grown, nothing about the PR has moved. Each
report carries an invisible `ci-watchdog-observation` marker naming what it
saw, which is what a later tick compares against; editing or deleting the
most recent report makes the next tick treat its observation as new.

## When the watchdog job goes red

Check the job log for a line starting with `Sweep`. Its presence, or
absence, tells you which of three things happened:

- **No `Sweep` line at all.** The job died before the loop finished, so
    nothing was attempted. Usually enumerating open PRs failed — that call
    sits outside the per-PR try/catch, so it aborts before any PR is
    processed — but harden-runner, checkout, or the job timeout produce the
    same silence. Read the log's stack trace directly; the per-PR guidance
    below does not apply.
- **`Sweep halted by rate limit; ...`.** The sweep hit a rate limit partway
    through and stopped rather than keep spending an exhausted budget. The PRs
    listed as "not attempted" were never touched this run — they are not
    errors, they are untried. The next scheduled run picks them up.
- **`Sweep completed; N PR(s) errored: ...`.** Every open PR was attempted.
    The named PRs errored while being processed; everything else succeeded or
    had nothing to do.

```text
Sweep completed; 2 PR(s) errored: #N, #M
```

For each PR named as errored, find its `core.error` line in the job log.
`core.error` emits a workflow `::error::` command, and `@actions/core`
escapes newlines in it to `%0A` — so in the raw job log it is one line with
literal `%0A` separating the status from each stack frame:

```text
::error::PR #N: 404 HttpError: Not Found%0A    at ... listWorkflowRunsForRepo ...
```

Search the raw log for `PR #N:` to find it. GitHub renders the same
`core.error` call as a multi-line entry in the job's Annotations panel — use
that view if you want it split into lines instead of `%0A`-joined:

```text
PR #N: 404 HttpError: Not Found
    at ... listWorkflowRunsForRepo ...
```

The status and the stack frame together identify which API call failed and
why. Work from those:

1. A `404` or `422` usually means the PR moved under the sweep — closed,
    merged, or force-pushed between enumeration and processing. Harmless; it
    clears on the next sweep.
1. A `403` on `listWorkflowRunsForRepo`, `issues.listForRepo`, or similar
    read/write calls, on a PR in the "errored" list of a `Sweep completed`
    message, is a permissions gap — check the job's `permissions:` block
    against the call in the stack. If the message is instead
    `Sweep halted by rate limit`, the errored PR's 403 is the rate limit that
    triggered the halt; the PRs in its "not attempted" list get no
    `core.error` line at all because the sweep never reached them — nothing
    to check there, they are simply picked up on the next scheduled run.
1. A `403` on `reRunWorkflowFailedJobs` specifically, with a message like
    "Unable to retry this workflow run because it was created over a month
    ago", is neither of those — GitHub refuses to re-run runs past roughly a
    month old. This is not rare: a bot PR can sit long enough for its run to
    age out, and once it does, every sweep errors on it forever. The watchdog
    cannot fix this itself; the PR needs a fresh commit to produce a new run,
    or should be closed.
1. A `5xx` that reached this log already exhausted the step's own request
    retries, so it is a sustained GitHub incident rather than a blip. Check
    the GitHub status page.

A PR that errors on **every** sweep is a real bug, not a transient. It is
also the case worth acting on quickly: while it is failing it is not being
retried, so if it is a bot PR with auto-merge on, it is sitting stuck for
exactly the reason this watchdog exists.

## Forcing a run

`gh workflow run ci-watchdog.yml`
