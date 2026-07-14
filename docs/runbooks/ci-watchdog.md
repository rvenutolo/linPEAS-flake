# Runbook: CI retry watchdog

## What it does

`ci-watchdog` runs every 30 minutes. It finds open bot-authored pull
requests that have auto-merge enabled and a failed workflow run on their
current head commit, and re-runs the failed jobs.

Each run gets at most 3 attempts. `gh run rerun --failed` re-runs a run in
place and increments its attempt counter, so the bound needs no stored
state — and a new commit resets it, because a new commit produces a new run
at attempt 1.

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

The watchdog re-ran the PR's failed jobs 3 times and they failed every time.
That is no longer a transient — treat it as a real failure.

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

## Forcing a run

`gh workflow run ci-watchdog.yml`
