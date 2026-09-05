# Seeded-defect recall harness

Measures how reliably `docs-correctness-audit` (`/docs-audit`) detects
single-instance defects. `plant.sh` seeds one known defect per category into a
disposable `git worktree`; you run the audit M times against that copy;
`score.sh` reports per-category recall and run-to-run variance.

## Run trigger

**The audit loop is manual only, and not wired into CI** — a full audit runs
on the order of ten minutes and, across the four user-facing clusters, ~240k reader-tokens per run
summed across readers (see [`../tuning-results.md`](../tuning-results.md) for the measured table;
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
    harness="$PWD"   # this directory; the cp below needs it from inside the worktree
    cd "$(cat results/worktree-path.txt)"
    claude            # then run: /docs-audit
    ```

    After each run, copy the emitted report into the harness `results/` dir:

    ```sh
    cp .claude/reports/*-docs-correctness-findings.md \
      "$harness"/results/run-1.md   # run-2.md, run-3.md, ...
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
    `ephemeral-token`, `drifted-cron`, `stale-path`) lean on a deterministic
    bundle section — the ephemeral / link / CI-name / required-check-count
    sweeps, the cron table, and the script inventory — expect high, stable
    recall.
- **Reasoning-driven** seeds (`mislabel-member`, `false-exclusive`,
    `near-miss-exclusive`) need a
    comparison the bundle supports but does not perform — the union allowlist
    contains the name and the mislabel is a semantic distinction; the
    `false-exclusive` payload turns on step-level detail the bundle carries
    nowhere, so refuting it means opening the workflow — expect the flaky
    tail. A low number there is a measurement, not a bug in the
    harness. The class is seeded at both ends: `false-exclusive` is flatly
    false (no job lacks the step it names), while `near-miss-exclusive` is true
    of every member of its set but one, and that one exception is listed in the
    same table the claim sits under. The near-miss was expected to be the
    weaker of the two, on the reasoning that a reader who spot-checks two or
    three members finds nothing wrong; measured, both hit 2/2. Two runs is too
    thin to retire the concern, so treat the expectation as open rather than
    refuted. A later M=2 run settled it the other way: `near-miss-exclusive`
    came back 1/2 FLAKY while `false-exclusive` held 2/2, which is the
    predicted ordering. Treat the near-miss end of the class as the weaker
    one, and expect it to carry the set's flake.
- **Rewrite-shaped** seeds (`distant-contradiction`, `dangling-deixis`) carry
    no bundle support whatsoever and are the hardest of the set. Both encode a
    defect a fix pass leaves behind rather than one that rots on its own:
    `distant-contradiction` plants a claim under `## Tools needed` that the
    cosign section refutes hundreds of lines below, so a reader who reads the
    paragraph — or even the whole section — and stops will miss it;
    `dangling-deixis` plants "the three checkers listed below" where nothing
    below lists three of anything, which is caught only by resolving the
    pointer instead of reading past it. Both were expected to be the flakiest
    column, on the reasoning that they measure how far a reader searches
    rather than whether a fact is checkable. Measured at M=2, both hit 2/2
    with no flake — so that expectation is refuted, not merely open. Read a
    future low number as a statement about search depth rather than as a
    broken seed, but do not predict one.

## A confound to keep in view

Every seed is planted with `insert-after` against a heading anchor, so each
one lands as a lone sentence directly below a heading. That shape is itself a
tell: a reader can learn to spot it without doing the verification the seed
exists to measure, and it trips markdownlint's MD022 as a side effect — one
scored run filed the glued-under-heading formatting as a finding in its own
right and named the seeded headings. Recall measured this way is therefore an
upper bound. Varying the insertion point into paragraph interiors would
tighten it, at the cost of re-measuring every seed from scratch.

## Tests

`plant.test.sh` and `score.test.sh` are cheap, deterministic, and need no audit
run. They validate the harness mechanics (planting, manifest, scoring math),
not the audit. Together with `../../scripts/collect-ground-truth.test.sh` they
are registered in `scripts/run-harness-group.sh` as `docs-audit-plant`,
`docs-audit-score` and `docs-audit-ground-truth`, and run in the required
`harness-group` CI job. Only the audit loop itself stays manual.
