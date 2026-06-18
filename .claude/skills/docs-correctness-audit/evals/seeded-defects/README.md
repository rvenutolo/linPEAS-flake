# Seeded-defect recall harness

Measures how reliably `docs-correctness-audit` (`/docs-audit`) detects
single-instance defects. `plant.sh` seeds one known defect per category into a
disposable `git worktree`; you run the audit M times against that copy;
`score.sh` reports per-category recall and run-to-run variance.

## Run trigger

**Manual only. Not wired into CI** — a full audit is ~9 min and ~100k+ tokens;
M runs multiply that. Run this when you want a recall number (e.g. before/after
a skill edit), not on every change.

## Steps

1. Plant the defects:

    ```sh
    ./plant.sh
    ```

    Builds a worktree at `${TMPDIR:-/tmp}/docs-audit-seeded-defects`, copies the
    skill in, applies all seeds, and writes `results/manifest-resolved.json`.

1. Run the audit M times (default M=3), fresh session each:

    ```sh
    cd "$(cat results/worktree-path.txt)"
    claude            # then run: /docs-audit
    ```

    After each run, copy the emitted report into the harness `results/` dir:

    ```sh
    cp .claude/reports/*-docs-correctness-findings.md \
      <harness>/results/run-1.md   # run-2.md, run-3.md, ...
    ```

1. Score:

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

Setup is deterministic — fixed sentinels, fixed seeds, a clean `main` worktree.
The **only** stochastic part is the audit itself; that variance (the FLAKY
column) is exactly the signal being measured.

## Expected recall profile

- **Collector-driven** seeds (`broken-link`, `ghost-job`, `wrong-check-count`)
    lean on the deterministic ephemeral/link/CI-name sweeps — expect high, stable
    recall.
- **Reasoning-driven** seeds (`mislabel-member`, `drifted-cron`, `stale-path`)
    lean on reader judgment — expect the flaky tail. A low number there is a
    measurement, not a bug in the harness.

## Tests

`plant.test.sh` and `score.test.sh` are cheap, deterministic, and need no audit
run. They validate the harness mechanics (planting, manifest, scoring math),
not the audit. The audit loop stays manual.
