# Seeded-defect recall harness

Measures how reliably `docs-correctness-audit` (`/docs-audit`) detects
single-instance defects. `plant.sh` seeds one known defect per category into a
disposable `git worktree`; you run the audit M times against that copy;
`score.sh` reports per-category recall and run-to-run variance.

## Run trigger

**The audit loop is manual only, and not wired into CI** — a full audit is
~9 min and, across the four user-facing clusters, ~240k mean reader-tokens per
run (see [`../tuning-results.md`](../tuning-results.md) for the measured table;
the `claude-tooling` reader is additional and unmeasured); M runs
multiply that. Run it when you want a recall number (e.g. before/after a skill
edit), not on every change. The harness's own tests do run in CI; see Tests
below.

## Steps

1. Plant the defects:

    ```sh
    ./plant.sh
    ```

    Adds a detached worktree at HEAD under
    `${TMPDIR:-/tmp}/docs-audit-seeded-defects` — the tracked skill is checked
    out with it, so nothing is copied — applies all seeds, and writes
    `results/manifest-resolved.json` plus `results/worktree-path.txt`.

1. Run the audit M times (default M=2, matching the ship gate in
    [`../tuning-results.md`](../tuning-results.md)), fresh session each:

    ```sh
    cd "$(cat results/worktree-path.txt)"
    claude            # then run: /docs-audit
    ```

    After each run, copy the emitted report into the harness `results/` dir:

    ```sh
    cp .claude/reports/*-docs-correctness-findings.md \
      <harness>/results/run-1.md   # run-2.md, run-3.md, ...
    ```

1. Score — back in the original checkout's harness directory, not the
    planted worktree (the worktree has the same tracked `score.sh` but no
    untracked `results/`, so running it there exits 1):

    ```sh
    ./score.sh results/run-*.md
    ```

    Writes `results/recall-<stamp>.md` with per-category recall, a per-seed
    hit/miss matrix across the M runs, and a FLAKY flag for seeds caught in some
    runs but not all.

1. Tear down:

    ```sh
    ./plant.sh --clean
    ```

## Determinism

Setup is deterministic — fixed sentinels, fixed seeds, a worktree detached
at `HEAD`.
The **only** stochastic part is the audit itself; that variance (the FLAKY
column) is exactly the signal being measured.

## Expected recall profile

- **Collector-driven** seeds (`broken-link`, `ghost-job`, `wrong-check-count`,
    `ephemeral-token`) lean on the deterministic ephemeral / link / CI-name / required-check-count
    sections of the bundle —
    expect high, stable recall.
- **Reasoning-driven** seeds (`mislabel-member`, `drifted-cron`, `stale-path`)
    lean on reader judgment — expect the flaky tail. A low number there is a
    measurement, not a bug in the harness.

## Tests

`plant.test.sh` and `score.test.sh` are cheap, deterministic, and need no audit
run. They validate the harness mechanics (planting, manifest, scoring math),
not the audit. Together with `../../scripts/collect-ground-truth.test.sh` they
are registered in `scripts/run-harness-group.sh` as `docs-audit-plant`,
`docs-audit-score` and `docs-audit-ground-truth`, and run in the required
`harness-group` CI job. Only the audit loop itself stays manual.
