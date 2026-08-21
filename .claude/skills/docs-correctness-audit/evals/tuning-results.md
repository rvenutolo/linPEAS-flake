# Cluster-granularity tuning results

Why the audit covers the `docs/` tree with **four** read-only cluster readers
(the map in [`../references/repo-map.md`](../references/repo-map.md) §2) rather
than one per `docs/` subdirectory. The `claude-tooling` reader in that map is
outside this comparison: it reads the audit's own specification, not the `docs/`
tree, so no `docs/` granularity choice applies to it. The numbers below come
from the seeded-defect recall harness in [`seeded-defects/`](seeded-defects/)
(`plant.sh` → run the audit → `score.sh`), run twice per configuration against
the same seven planted defects.

## Configurations compared

- **per-subdirectory** — seven readers: `reference`, `security`,
    `architecture`, `install`, `runbooks`, `development`, `root + misc`.
- **merged (shipped)** — four readers: `core-docs`
    (`reference`+`install`+`runbooks`), `security`, `arch+dev`
    (`architecture`+`development`), `root + misc`.
- **security+root merged** — three readers: `core-docs`, `arch+dev`, and one
    reader covering `security` and `root + misc` together.

## Result

| Configuration        | Readers | Seed recall (2 runs) | Mean reader-tokens/run | Cut  |
| -------------------- | ------- | -------------------- | ---------------------- | ---- |
| per-subdirectory     | 7       | 14/14 (100%)         | ~339k                  | —    |
| merged (shipped)     | 4       | 14/14 (100%)         | ~240k                  | ~29% |
| security+root merged | 3       | 14/14 (100%)         | not comparable         | —    |

All three configurations catch all seven seeds in both runs — every category
(ghost CI job, lint-group mislabel, cron drift, stale script ref, broken
internal link, required-check count, ephemeral token). The merged map cuts mean
reader-tokens ~29% because most of a reader's cost is fixed per-agent overhead
(re-reading the ground-truth bundle, tool setup); three readers collapsed into
one (`core-docs`) eliminate that overhead while the same documents still get
read once.

Token figures are this harness's per-reader accounting (sum of subagent token
usage), not a single controller-visible total; treat the **ratio**, not the
absolute, as the portable result. The third row's cost cell is deliberately
empty: that configuration was measured in a separate session, against a tree
whose known drift had just been corrected, so its token total is not
commensurable with the first two rows. Recall is still comparable, because
14/14 is the ceiling — a configuration cannot beat it, only fall short.

## Tradeoff and guardrail

Merging trades some thoroughness on **low-severity, non-seeded** drift: a reader
covering more files spreads attention thinner and skips minor prose-imprecision
findings that a dedicated reader surfaces. All **high-severity** detections held
across every run of every configuration.

`security` and `root + misc` are nonetheless kept standalone in the shipped map,
and the reason is a judgement rather than a measurement. Merging them was
measured and did **not** regress seed recall: the single combined reader caught
all five seeds in its half of the tree, twice. What the harness cannot measure is
depth on non-seeded drift, and those two clusters carry the densest such surface
(member-vs-job CI prose, required-check counts, ghost jobs, broken links). Seven
planted single-instance defects say nothing about how thoroughly a reader mines a
file it has already skimmed, so the four-reader map stands as the conservative
default — not as a measured optimum. Anyone wanting the three-reader map should
argue it on cost measured head-to-head in one session, which the row above is
explicitly not.

## How to re-measure

Paths below are relative to this file's directory — `cd` to the skill's
`evals/` directory first.

```sh
bash seeded-defects/plant.sh
# run /docs-audit against the planted worktree, save the report, repeat
bash seeded-defects/score.sh <report1.md> <report2.md>
bash seeded-defects/plant.sh --clean
```

A configuration ships only if seed recall holds at 14/14 across two runs (no
high-severity category dropped) **and** mean reader-tokens fall below the
per-subdirectory baseline. A finding inside the baseline's run-to-run noise is
inconclusive, not a win.
