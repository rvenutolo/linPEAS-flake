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
1. Run each selected dimension as its own gated `Workflow`, dimension 6 before dimension 5 so 6's confirmed findings can seed 5 — wait for "go",
    fan out finder slices, refute every finding (up to the per-dimension
    cap of 25, most-severe first; report the cap when it fires) with 3
    default-refuted skeptics, keeping a finding when at least two of the skeptics that
    returned could not refute it. Seed later dimensions with earlier
    confirmed findings.
1. Append survivors — plus the refutation log and any contested kills (one
    live skeptic of at least two dissenting), which are never dropped silently — to one
    severity-ranked report under `.claude/reports/`.

This is a READ-ONLY review: edit nothing, mutate nothing in the checkout (not
even a generated file's mtime — use `nix build --no-link` so no `result`
symlink lands); end by confirming `git status` shows no modified tracked files.
The one exception is dimension 5's mutation testing, which runs in a detached
`git worktree` under `$TMPDIR` and tears it down afterwards. If the user passed an
argument naming a subset (e.g. `2,5` or `nix`), scope to those dimensions but
keep the same method.

$ARGUMENTS
