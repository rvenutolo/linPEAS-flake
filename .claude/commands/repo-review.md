---
description: Multi-agent refute-all review across 8 fixed dimensions — severity-ranked report, no edits
---

Run a multi-agent, refute-all review of this repository using the
`multi-agent-review` skill. Invoke that skill and follow it exactly:

1. Read its [`references/dimensions.md`](../skills/multi-agent-review/references/dimensions.md)
    for the 8 hardcoded dimensions, their finder slices, and per-dimension
    refuter guidance.
1. Scope the review with the user via `AskUserQuestion`: per-dimension
    deep/light/skip (dim 3 adversarial, dim 7 advisory), and confirm the
    run-wide defaults (refute-all verification, single `.claude/reports/`
    report, per-dimension gates).
1. Run each selected dimension as its own gated `Workflow` — wait for "go",
    fan out finder slices, refute every finding with 3 default-refuted
    skeptics, keeping a finding when at least two of the skeptics that
    returned could not refute it. Seed later dimensions with earlier
    confirmed findings.
1. Append survivors — plus the refutation log and any contested kills (one
    live skeptic dissenting), which are never dropped silently — to one
    severity-ranked report under `.claude/reports/`.

This is a READ-ONLY review: edit nothing, mutate nothing (not even a generated
file's mtime); end by confirming `git status` shows no modified tracked files. If the user passed an
argument naming a subset (e.g. `2,5` or `nix`), scope to those dimensions but
keep the same method.

$ARGUMENTS
