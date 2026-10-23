# CI retry watchdog runbook

## What it does

`ci-watchdog` runs on a cron schedule
(see [CI — cron schedule](../architecture/ci.md#cron-schedule)) and on the
`workflow_run` completion of every other workflow, so a failure is usually
retried minutes after it happens and the cron is the fallback. A
`workflow_run` completion that concluded `success` or `skipped` leaves
nothing to retry, so the job's `if:` skips it, which keeps the sweep's API
requests down. It also skips a completion whose head is in another
repository (a fork PR's CI), so a fork cannot start a sweep that holds
`actions: write` and `issues: write`. Such a no-op run gets a
concurrency group of its own, so it cannot cancel a real sweep waiting in
the `ci-watchdog` group. The cron and `workflow_dispatch` always sweep.
Each run is one sweep in two loops, and each loop asks
`scripts/classify-ci-run.sh` what to do with every candidate run. That
script is the single source of truth for which failures count.

The **bot-PR loop** finds open bot-authored pull requests that have
auto-merge enabled and a completed run on their current head commit that
concluded `failure`, `timed_out` or `cancelled`, and classifies each with
`--policy bot-pr`. The verdict is `retry` (re-run the failed jobs),
`exhausted` (escalate) or `ignore` (skip). A PR with any run still in
progress is deferred to the next sweep.

The **automated loop** covers the runs the repo starts itself: `push` runs
on `main`, `schedule` runs, and `workflow_run`-triggered runs (for example
`dockerhub-sync` and `renovate-flake-lock-refresh`). It lists those runs
created in the last 72 hours, and `scripts/select-automated-runs.sh` picks
the candidates from them. A candidate's latest attempt must have finished
(its `updated_at`) in the last 24 hours, so the first sweep after a deploy
does not retry old history, while a run created before that window whose
re-run finished inside it is still retried or filed. It drops the
watchdog's own runs, which the classifier would only report, so a failing watchdog does not
fetch its own failed runs on every sweep. For `push` and `schedule` it
keeps only the newest run of each workflow per event: a newer run, finished
or still in progress, replaced the older ones. Every `workflow_run` run is a
candidate on its own, because each is chained to a different upstream run.
A `skipped` run never replaces anything: `renovate-flake-lock-refresh`, for
one, concludes `skipped` on nearly every `ci` completion, and counting that
as a newer run would hide the failure before it. A candidate that concluded
`failure`, `cancelled` or `timed_out` is classified with
`--policy automated`, which retries only when every counted job is
transient — it failed in a setup step before the job's own work, lost its
runner, or timed out — so a real regression is reported on its first
attempt instead of being retried. The verdicts are `retry`, `exhausted`,
`report` (a real failure, or a run the policy does not retry: nothing to
do here, the workflow's own notify job files it) and `ignore`.
`workflow_dispatch` runs are not covered: a person started them and can
re-run them. A run the bot-PR loop already re-ran or escalated in the same
sweep is skipped, so one sweep never acts on a run twice.

The `notify-workflow-result` composite holds an issue off on exactly the
`--policy automated` verdict `retry`, so every failure it holds off on is
one this loop re-runs (see the hold-off paragraphs under
[Cancelled-job attribution](../architecture/ci.md#cancelled-job-attribution)).

`release-on-bump` is excluded from automated retries: the classifier
answers `report` for its runs, so its own notify job files on the first
failure and the [Docker Hub recovery runbook](dockerhub-recovery.md) stays
the recovery path. A re-run of its failed jobs is not idempotent. If the
`release` job is lost after `gh release create` (a timeout or a lost
runner, both transient-shaped), the re-run reads `tag-exists=true` and
skips every image, manifest, changelog and verify job, finishing green with
no images published. If an image job is lost after its docker.io push and
before its ghcr.io push, the re-run rebuilds and pushes over the orphan
docker.io tag that the recovery runbook deletes first.

`reRunWorkflowFailedJobs` re-runs jobs whose conclusion is `cancelled` as
well as failed ones, and every job that depends on them, notify jobs
included, so a re-run that succeeds closes or skips the workflow's issue as
a first run would. A re-run started with the workflow's `GITHUB_TOKEN`
still fires `workflow_run` when it completes, so every attempt, not only
the first, is picked up minutes after it finishes rather than on the next
cron tick. GitHub does not chain `workflow_run` more than three workflows
deep, so a completion further down a chain than that reaches the watchdog
only through the cron.

A job that exceeds its timeout is recorded by GitHub as `cancelled`, not
`timed_out`, so the classifier recognizes it by the job's annotation and
counts it like any other failure. A job that concluded `cancelled` is otherwise not counted,
for one of two reasons. A cancel by a newer run in the same concurrency
group is superseded: re-running it would resurrect a run for a replaced
commit. Any other cancel (manual, or a job that never got a runner) carries
no timeout evidence, so there is nothing to count.

Each run gets at most 3 attempts. `reRunWorkflowFailedJobs` re-runs a run in
place and increments its attempt counter, so the bound needs no stored
state — and a new commit resets it, because a new commit produces a new run
at attempt 1.

Separately from that 3-attempt run bound, the watchdog's own API requests
retry on anything not in the exempt list below — in practice a 5xx.
Malformed, unauthorized, or missing-resource requests, conflicts,
already-exists responses, and all 403s are exempt: a 400,
401, or 404 will not become valid on a second try, a 409 means the re-run
already took effect, a 422 lets `createLabel`'s try/catch see the
already-exists conflict immediately, and the 403 entry is a bare status
code — it exempts a permissions gap exactly as it exempts a rate limit.
Neither becomes valid on an immediate retry, and a rate limit is made
worse by one.

An error that survives that retry is confined to the item it happened
on: a PR in the bot-PR loop, a run in the automated loop. The sweep
processes every remaining item in both loops and then fails the job,
naming the items that errored. The one exception is a rate limit:
continuing to request against an exhausted budget can make it worse, so
the sweep halts instead, in whichever loop it is in (on an Octokit 403
carrying rate-limit headers, or on a `gh api` failure in
`scripts/fetch-ci-run.sh` whose stderr names a rate limit with `HTTP 403`
or `HTTP 429`), and fails the job naming both the items that errored and
the items it left untried (how to read that "not attempted" list is
covered under the rate-limit entry below). Either way, no item is starved
silently and no error is swallowed. The one swallowed status is `createLabel`'s
422, which means the escalation label already exists and is not an error
at all.

Under the `bot-pr` policy every counted failure is retried, without a
hand-maintained list of transient signatures; such lists rot silently. It
could not work here anyway: `connection refused` is both the signature of a
CDN blip and the signature of a harden-runner egress block, which is a
permanent configuration bug. The classifier does still tag every counted
failure with a class and a reason, and the watchdog lists those tags in the
re-run notice and in the escalation issue.

The watchdog fetches each candidate run through `scripts/fetch-ci-run.sh`,
which reads job annotations and so needs `checks: read` beside the
`actions: write` the re-run holds. A fetch or classifier failure counts as an
error against that PR or run, handled like any other per-item error below.

## Why it exists

Nothing else in this repo re-runs a failed job. A bot PR with auto-merge
enabled that hits a transient infrastructure failure will sit open forever,
because auto-merge waits for checks that will never re-run. A scheduled or
`main` run that hits one stays red, and files a notify issue for a blip,
until its next trigger.

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
close instruction above waits for the PR to merge or close) and comments
on it only when a later tick again finds exhausted runs and their set
differs from the last report (different head commit, run ids, attempt
counts, or conclusions — a pushed fix therefore goes silent until the
new runs exhaust the budget too). A streak of ticks that sees the same
thing stays silent, so the issue's comment thread is a list of changes,
not a heartbeat: if it has not grown, no new exhaustion has been
observed. Each report carries an invisible `ci-watchdog-observation`
marker naming what it saw, and a later tick compares against the newest
surviving marker: editing the marker out of the most recent report and
deleting that report both fall back to the previous marker — which stays
silent if it carries the same observation, and reports as new if no
marker survives.

## When you get a `ci-watchdog: <workflow> (<event>) exhausted retries` issue

The automated loop re-ran the newest `<event>` run of `<workflow>` until
its 3-attempt budget was spent, and every attempt failed only for
transient-shaped reasons (setup step, lost runner, timeout). The watchdog
files this issue only for a workflow that does not call the
`notify-workflow-result` composite: one whose workflow file has no step
`uses:` of it, neither the local path
`./.github/actions/notify-workflow-result` nor the pinned self-reference
`rvenutolo/linPEAS-flake/.github/actions/notify-workflow-result@<sha>`.
A workflow that calls it files its own issue through
it on the final attempt, and the watchdog only prints a notice, so one
failure never gets two issues. If the watchdog cannot read the workflow
file to tell, it logs a warning and files, because an unfiled exhausted
run is the worse mistake. A real failure in a workflow without a notify
job is not retried and gets no watchdog issue; it stays red in the
Actions tab.

1. Open the run URL in the issue body and read each listed job's log. The
    class and reason beside each job name say what the classifier saw.
1. A failure that recurs across three attempts in a setup step is usually
    an outage (GitHub, `cache.nixos.org`, a registry) or a harden-runner
    egress block on a host the setup step needs. Treat it as you would the
    bot-PR case above.
1. Once the cause is fixed or has cleared, re-run the run
    (`gh run rerun <run-id> --failed`) or wait for the next trigger, and
    close the issue when the workflow is green.

The issue is deduped by title and commented on only when a later sweep
sees a different exhausted run or attempt, exactly as for the bot-PR
issue above.

## When the watchdog itself fails

A `ci-watchdog: the retry sweep itself failed` issue, labelled
`ci-watchdog-failure`, means a sweep's `retry` job failed or was
cancelled. The watchdog's own `notify` job files it through the
`notify-workflow-result` composite. The classifier reports the
watchdog's own runs without retrying them (it lists
`.github/workflows/ci-watchdog.yml` beside `release-on-bump.yml` in
`AUTOMATED_EXCLUDED_PATHS`), so the issue is filed on the first failed
sweep rather than held off for a retry nobody would run. The `notify`
job is skipped when `retry` is skipped, as on a no-op `workflow_run`
completion, and the next successful sweep closes the issue.

While sweeps fail, every failure another workflow's notify job held off
for a retry is neither re-run nor filed, and bot PRs stuck on a transient
failure stay stuck. Read the failed `retry` log as the next section
describes, fix the cause, and then run a sweep by hand (see
[Forcing a run](#forcing-a-run)). That sweep picks up a held-off
failure whose latest attempt finished in the last 24 hours; an older one
it does not, so check
the Actions tab for red automated runs from the outage and re-run them
with `gh run rerun <run-id> --failed`.

## When the watchdog's `retry` job goes red

Search the job log for `Sweep`. Both verdicts are emitted through
`core.setFailed`, so the raw log renders them as `::error::Sweep ...`
rather than as a line starting with the word. Its presence, or absence,
tells you which of three things happened:

- **No `Sweep` line at all.** The job died before the loop finished, so
    the sweep produced no verdict. Usually enumerating open PRs failed —
    that call sits outside the per-PR try/catch, so it aborts before any PR
    is processed — but harden-runner, checkout, or the job timeout produce
    the same silence (a timeout can fire mid-loop, after some runs were
    already re-run). Read the log's stack trace directly; the per-item
    guidance below does not apply. Enumerating the automated runs is
    different: its failure is caught and reported as the item
    `automated-run enumeration`, and the bot-PR loop's work stands. If the
    run holds no `retry` log at all, the job never started and there is no
    stack trace to read — see
    [Cancelled-job attribution](../architecture/ci.md#cancelled-job-attribution).
- **`Sweep halted by rate limit; ...`.** The sweep hit a rate limit partway
    through and stopped rather than keep spending an exhausted budget. The
    items listed as "not attempted" were never touched this run — they are
    not errors, they are untried. A halt in the bot-PR loop lists every open
    PR behind the halt point, before the bot-author and auto-merge filters,
    so most entries are usually PRs the sweep would have skipped without
    touching anyway. Its last entry is
    `every automated run (sweep not started)`, because the automated loop
    never ran. A halt in the
    automated loop lists the candidate runs behind the halt point as
    `run <id> (<workflow>, <event>)`. The next sweep picks them up. Both signals trigger it:
    a 403 on an Octokit call whose response carries `x-ratelimit-remaining: 0`
    or `retry-after`, and a `Command failed` error from
    `scripts/fetch-ci-run.sh` whose `gh:` stderr line names a rate limit and
    ends `(HTTP 403)` or `(HTTP 429)`.
- **`Sweep completed; N item(s) errored: ...`.** Every open PR and every
    candidate run was attempted. The named items errored while being
    processed; everything else succeeded or had nothing to do.

```text
Sweep completed; 2 item(s) errored: PR #N, run 123 (ci, push)
```

For each item named as errored, find its `core.error` line in the job log.
`core.error` emits a workflow `::error::` command, and `@actions/core`
escapes newlines in it to `%0A` — so in the raw job log it is one line with
literal `%0A` separating the status from each stack frame:

```text
::error::PR #N: 404 HttpError: Not Found%0A    at ... listWorkflowRunsForRepo ...
```

Search the raw log for `PR #N:` (or `run <id> (` for an automated run)
to find it. GitHub renders the same
`core.error` call as a multi-line entry in the job's Annotations panel — use
that view if you want it split into lines instead of `%0A`-joined:

```text
PR #N: 404 HttpError: Not Found
    at ... listWorkflowRunsForRepo ...
```

The status and the stack frame together identify which API call failed and
why. Work from those:

1. A `404` or `422` usually means the PR or run moved under the sweep —
    closed, merged, force-pushed, or re-run by someone else between
    enumeration and processing. Harmless; it clears on the next sweep.
1. A `403` on `listWorkflowRunsForRepo`, `issues.listForRepo`, or similar
    read/write calls, on an item in the "errored" list of a `Sweep completed`
    message, is usually a permissions gap — check the job's `permissions:`
    block against the call in the stack. A 403 whose response carries
    neither `x-ratelimit-remaining: 0` nor `retry-after` is not classified
    as a rate limit, so a header-less secondary limit can also land
    here (a `gh api` failure is judged by its stderr message instead; see
    the `Command failed` entry below). If the message is instead
    `Sweep halted by rate limit`, the errored item's 403 is the rate limit that
    triggered the halt; the items in its "not attempted" list get no
    `core.error` line at all because the sweep never reached them — nothing
    to check there, they are simply picked up on the next scheduled run.
1. A `403` on `reRunWorkflowFailedJobs` specifically, with a message like
    "Unable to retry this workflow run because it was created over a month
    ago", is neither of those — GitHub refuses to re-run runs past roughly a
    month old. This is not rare: a bot PR can sit long enough for its run to
    age out, and once it does, every sweep errors on it forever. The watchdog
    cannot fix this itself; the PR needs a fresh commit to produce a new run,
    or should be closed. The automated loop never meets this, because it
    lists runs created in the last 72 hours only.
1. A `5xx` from a GitHub API call made by the workflow script itself
    already exhausted the step's own request retries, so it is a sustained
    GitHub incident rather than a blip. Check the GitHub status page. A
    `5xx` from `gh api` inside `scripts/fetch-ci-run.sh` has had no retry at
    all; it surfaces as status 1 in the next entry, and the next tick tries
    again.
1. An error logged as `PR #N: <status> Error: Command failed: ...` (or
    `run <id> (...): ...`) came from
    `scripts/fetch-ci-run.sh` or `scripts/classify-ci-run.sh`, not from an
    API call the script made itself. Status 1 is an API failure: read the
    `gh:` line of stderr that follows. Status 2 is a bad argument or a
    response or input that is not the expected shape. `no status` with
    `Command failed` is the 180-second timeout. A `Command failed` naming
    `scripts/select-automated-runs.sh` is reported as
    `automated-run enumeration`, and no automated run was attempted. A
    failed `yq` read of a workflow file is not an error: it is a warning
    naming the file, and the watchdog files that run's exhaustion issue.

A PR or run that errors on **every** sweep is a real bug, not a transient. It is
also the case worth acting on quickly: while it is failing it is not being
retried, so if it is a bot PR with auto-merge on, it is sitting stuck for
exactly the reason this watchdog exists.

## Forcing a run

```bash
gh workflow run ci-watchdog.yml
```
