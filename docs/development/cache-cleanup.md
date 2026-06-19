# GitHub Actions cache cleanup

The `actions-cache-prune.yml` workflow keeps the repository's
Actions-cache namespace from accumulating stale entries. Two triggers:

## Daily cron

The `prune-stale` job runs daily and on manual
`workflow_dispatch`. It removes:

1. **Age-stale entries** — any cache entry whose `last_accessed_at`
    is older than 7 days. Active branches keep their caches warm; idle
    branches expire within a week.
1. **Orphan-ref entries** — any cache entry whose `ref` is no longer
    a live branch or open PR merge ref. Catches caches whose owning
    branch was deleted between runs.

## PR-close prune

The `prune-on-pr-close` job runs on every `pull_request: closed` event
(merged or abandoned). It removes all cache entries scoped to:

- `refs/pull/${PR_NUMBER}/merge`
- `refs/heads/${HEAD_REF}`

This shortens the cache-poisoning persistence window: a poisoned PR
cache is evicted immediately on PR close rather than waiting for the
daily cron sweep.

## Permissions

Both jobs declare `actions: write` (cache deletion) and `contents: read` (branch enumeration). No other scopes — this exact write-scope set is enforced by `scripts/check-permission-scopes.sh` via the per-job allowlist in `.github/permission-scopes.yml`. The fork-guard
`github.repository == 'rvenutolo/linPEAS-flake'` is on both jobs;
forked-repo PRs do not trigger prune logic.

## Failure semantics

A failed prune run is not load-bearing. Stale caches cost only space
and a small cache-key search penalty; they do not corrupt or block
release pipelines. The workflow does not page on failure.

## Recovery

If a prune mass-deleted entries by mistake (e.g. cron date arithmetic
drift), no action is required — the next CI run rebuilds caches from
scratch within a few minutes. Cache rebuilds are not paid in OCI image
publication time.

If the action-token rate-limits during a prune run, the workflow
fails cleanly and re-runs on the next cron tick. Manual recovery:
`gh workflow run actions-cache-prune.yml`.
