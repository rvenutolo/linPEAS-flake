# CI retry watchdog runbook

## What it does

`ci-watchdog` runs on a cron schedule
(see [CI — cron schedule](../architecture/ci.md#cron-schedule)). It finds
open bot-authored pull requests that have auto-merge enabled and a completed
run on their current head commit that concluded `failure` or `timed_out`, and
re-runs the failed jobs. A PR with any run still in progress is deferred to the
next tick, and `cancelled` runs are never re-run — they are nearly always
concurrency-group cancels superseded by a newer run.

Each run gets at most 3 attempts. `reRunWorkflowFailedJobs` re-runs a run in
place and increments its attempt counter, so the bound needs no stored
state — and a new commit resets it, because a new commit produces a new run
at attempt 1.

Separately from that 3-attempt run bound, the watchdog's own API requests
retry on anything not in the exempt list below — in practice a 5xx.
Rate limits, conflicts, already-exists responses, and
malformed, unauthorized, or missing-resource requests are exempt: a 400,
401, or 404 will not become valid on a second try, a 409 means the re-run
already took effect, a 422 lets `createLabel`'s try/catch see the
already-exists conflict immediately, and retrying a 403 rate limit only
makes it worse.

An error that survives that retry is confined to the PR it happened on. The
sweep processes every remaining PR and then fails the job, naming the PRs
that errored. The one exception is a rate limit: continuing to request
against an exhausted budget can make it worse, so the sweep halts instead
and fails the job naming both the PRs that errored and the PRs it left
untried (how to read that "not attempted" list is covered under the
rate-limit entry below). Either way, no PR is starved silently and no error is swallowed.
The one swallowed status is `createLabel`'s 422, which means the
escalation label already exists and is not an error at all.

The watchdog re-runs **any** failure, without trying to classify it as
transient. Classification would need a hand-maintained list of failure
signatures, and such lists rot silently. It also could not work here:
`connection refused` is both the signature of a CDN blip and the signature
of a harden-runner egress block, which is a permanent configuration bug.

## Why it exists

Nothing else in this repo re-runs a failed job. A bot PR with auto-merge
enabled that hits a transient infrastructure failure will sit open forever,
because auto-merge waits for checks that will never re-run.

## When you get a `ci-watchdog: PR #N exhausted retries` issue

The watchdog exhausted the PR's 3-attempt budget — the original run plus 2
re-runs — and the jobs failed every time. That is no longer a transient —
treat it as a real failure.

1. Open the run URLs listed in the issue body and read the failing job's log.
1. If the PR is genuinely broken (a dependency bump that breaks the build, a
    lint that genuinely fires), fix it or close the PR. The watchdog will not
    re-run its jobs again unless a new commit resets the attempt counter; it
    keeps watching the PR, but stays silent about the new runs unless they
    too exhaust the attempt budget.
1. If it is a real infrastructure failure that outlasted the 3-attempt budget (a
    multi-hour upstream outage), re-run manually once the outage clears:
    `gh run rerun <run-id> --failed`.
1. If the failure is a harden-runner egress block — a `connection refused`
    or `ECONNREFUSED` against a healthy public host — the allowlist is
    missing a host. Add it and check whether `check-egress-allowlist.sh`
    should have caught it; if it should have, the lint has a gap worth
    closing.

Close the issue once the PR merges or is closed.

The watchdog files ONE issue per stuck PR (deduped against *open*
`ci-watchdog`-labeled issues — closing the issue while the PR is still
stuck lets the next exhausting tick open a fresh one, which is why the
close instruction above waits for the PR to merge or close) and
comments on it only when a
later tick again found exhausted runs and their set differs from the
last report (different head commit, run ids, attempt counts, or
conclusions — a
pushed fix therefore goes silent until the new runs exhaust the budget
too). A streak of ticks that sees the
same thing stays silent, so the issue's comment thread is a list of changes,
not a heartbeat: if it has not grown, no new exhaustion has been
observed. Each
report carries an invisible `ci-watchdog-observation` marker naming what it
saw, and a later tick compares against the newest surviving marker: editing
the marker out of the most recent report makes the next tick treat its
observation as new, while merely deleting that report falls back to the
previous marker — which stays silent if it carries the same observation.

## When the watchdog's `retry` job goes red

Search the job log for `Sweep`. Both verdicts are emitted through
`core.setFailed`, so the raw log renders them as `::error::Sweep ...`
rather than as a line starting with the word. Its presence, or absence,
tells you which of three things happened:

- **No `Sweep` line at all.** The job died before the loop finished, so
    the sweep produced no verdict. Usually enumerating open PRs failed —
    that call sits outside the per-PR try/catch, so it aborts before any PR
    is processed — but harden-runner, checkout, or the job timeout produce
    the same silence (a timeout can fire mid-loop, after some PRs were
    already re-run). Read the log's stack trace directly; the per-PR
    guidance below does not apply.
- **`Sweep halted by rate limit; ...`.** The sweep hit a rate limit partway
    through and stopped rather than keep spending an exhausted budget. The PRs
    listed as "not attempted" were never touched this run — they are not
    errors, they are untried, and the list is every open PR behind the
    halt point before the bot-author and auto-merge filters, so most
    entries are usually PRs the sweep would have skipped without touching
    anyway. The next scheduled run picks them up.
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
    message, is usually a permissions gap — check the job's `permissions:`
    block against the call in the stack. A 403 whose response carries
    neither `x-ratelimit-remaining: 0` nor `retry-after` is not classified
    as a rate limit, so a header-less secondary limit can also land here. If the message is instead
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

```bash
gh workflow run ci-watchdog.yml
```
