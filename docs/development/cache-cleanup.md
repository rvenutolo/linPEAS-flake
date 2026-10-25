# GitHub Actions cache cleanup

The `actions-cache-prune.yml` workflow keeps the repository's
Actions-cache namespace from accumulating stale entries. Nothing in
this repo currently writes an Actions cache — no workflow or composite
action uses `actions/cache` or a `cache:` input, and Nix-based jobs
pull from the public `cache.nixos.org` substituter instead — so the
workflow is a standing guard: it bounds the lifetime of any cache a
future action, or a third-party action's opaque internal caching,
might create. Two automatic triggers, plus a manual
`workflow_dispatch` that drives only the daily-cron job:

## Daily cron

The `prune-stale` job runs daily. It removes:

1. **Age-stale entries** — any cache entry whose `last_accessed_at`
    is older than 7 days. Active branches keep their caches warm; idle
    branches expire within a week.
1. **Orphan-ref entries** — any cache entry whose `ref` is no longer
    a live branch or open PR merge ref. Catches caches whose owning
    branch was deleted between runs.

## PR-close prune

The `prune-on-pr-close` job runs on a `pull_request: closed` event for
a PR targeting `main` (merged or abandoned), subject to the fork guard
described under Permissions below. It removes all cache entries
scoped to:

- `refs/pull/${PR_NUMBER}/merge`
- `refs/heads/${HEAD_REF}`, only when the head ref holds nothing but
    ASCII letters, digits, `.`, `_`, `/` and `-`

`scripts/classify-pr-cache-refs.sh` computes that list. A branch name
may hold characters that change the cache listing query it is sent in
(`&` or `?` adds query parameters that select other refs' caches, and
`{owner}`, `{repo}` or `{branch}` is a placeholder `gh api` expands), so
a head ref outside that set is skipped with a log line and its caches
age out in the daily sweep; the merge ref is still pruned. The step also
passes each ref as a `gh api` query field, which gh URL-encodes, and sets
`GH_REPO` so gh never reads the repository from the checkout's git
remote.

This shortens the cache-poisoning persistence window: should any PR
cache exist, a poisoned one is evicted immediately on PR close rather
than waiting for the daily cron sweep.

## Permissions

Both prune jobs declare `actions: write` (cache deletion) and
`contents: read`, the scope GitHub documents for the branch listing
`prune-stale` does (on this public repository neither that listing nor
the open-PR one needs any token permission) and the checkout
`prune-on-pr-close` does to run `scripts/classify-pr-cache-refs.sh`. The `actions: write` grant is what
`scripts/check-permission-scopes.sh` pins, via the per-job allowlist in
`.github/permission-scopes.yml`; read scopes are outside that lint. The
`notify` job declares `issues: write` for the failure issue it files and
no other write scope. The
fork-guard `github.repository == 'rvenutolo/linPEAS-flake'` is on all
three jobs; it
keeps the workflow inert in forks of this repository. A PR opened
*from* a fork against `main` still runs `prune-on-pr-close`, since
`github.repository` on a `pull_request` event names the base repo.

## Failure semantics

A failed prune run is not load-bearing. Stale caches cost only space
and a small cache-key search penalty; they do not corrupt or block
release pipelines. A failed run still files a deduped
`actions-cache-prune-failure` issue through the `notify` job, on every
trigger, the PR-close prune included, because nobody watches a closed
PR's runs. The next passing run closes it.

## Recovery

If a prune mass-deleted entries by mistake (e.g. cron date arithmetic
drift), no action is required — no CI job reads an Actions cache, so
nothing is lost but the entries themselves; any action that does cache
opaquely repopulates on its next run. No release-path job waits on a
cache warm-up, so a mass deletion costs nothing in image-publication
latency.

If the action-token rate-limits on one of the delete calls, the
workflow fails cleanly and re-runs on the next cron tick. A rate limit
that lands on a cache enumeration instead is swallowed — every cache
enumeration feeds a `while` loop from a process substitution, whose
exit status is discarded even under
`set -Eeuo pipefail` — so that run reports zero deletions and goes
green. Manual recovery for the daily sweep either way:
`gh workflow run actions-cache-prune.yml`; a swallowed PR-close prune
is picked up by a later orphan-ref sweep instead, which evicts the
merge ref's cache on the next tick and the head ref's once the branch
is deleted.
