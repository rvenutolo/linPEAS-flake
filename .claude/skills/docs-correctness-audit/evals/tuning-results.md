# Cluster-granularity tuning results

Why the audit fans out **four** read-only cluster readers (the map in
[`../references/repo-map.md`](../references/repo-map.md) §2) rather than one per
`docs/` subdirectory. The numbers below come from the seeded-defect recall
harness in [`seeded-defects/`](seeded-defects/) (`plant.sh` → run the audit →
`score.sh`), run twice per configuration against the same seven planted defects.

## Configurations compared

- **per-subdirectory** — seven readers: `reference`, `security`,
    `architecture`, `install`, `runbooks`, `development`, `root + misc`.
- **merged (shipped)** — four readers: `core-docs`
    (`reference`+`install`+`runbooks`), `security`, `arch+dev`
    (`architecture`+`development`), `root + misc`.

## Result

| Configuration    | Readers | Seed recall (2 runs) | Mean reader-tokens/run | Cut  |
| ---------------- | ------- | -------------------- | ---------------------- | ---- |
| per-subdirectory | 7       | 14/14 (100%)         | ~339k                  | —    |
| merged (shipped) | 4       | 14/14 (100%)         | ~240k                  | ~29% |

Both configurations catch all seven seeds in both runs — every category
(ghost CI job, lint-group mislabel, cron drift, stale script ref, broken
internal link, required-check count, ephemeral token). The merged map cuts mean
reader-tokens ~29% because most of a reader's cost is fixed per-agent overhead
(re-reading the ground-truth bundle, tool setup); three readers collapsed into
one (`core-docs`) eliminate that overhead while the same documents still get
read once.

Token figures are this harness's per-reader accounting (sum of subagent token
usage), not a single controller-visible total; treat the **ratio**, not the
absolute, as the portable result.

## Tradeoff and guardrail

Merging trades some thoroughness on **low-severity, non-seeded** drift: a reader
covering more files spreads attention thinner and skips minor prose-imprecision
findings that a dedicated reader surfaces. All **high-severity** detections held
across both runs. `security` and `root + misc` are kept standalone for exactly
this reason — they carry the dense, high-severity drift surfaces (member-vs-job
CI prose; required-check counts, ghost jobs, broken links), and merging them
regresses high-severity recall.

## How to re-measure

```sh
bash evals/seeded-defects/plant.sh
# run /docs-audit against the planted worktree, save the report, repeat
bash evals/seeded-defects/score.sh <report1.md> <report2.md>
bash evals/seeded-defects/plant.sh --clean
```

A configuration ships only if seed recall holds at 14/14 across two runs (no
high-severity category dropped) **and** mean reader-tokens fall below the
per-subdirectory baseline. A finding inside the baseline's run-to-run noise is
inconclusive, not a win.
