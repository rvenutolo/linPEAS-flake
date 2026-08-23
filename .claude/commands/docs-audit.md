---
description: Read-only documentation correctness audit — severity-ranked findings report, no edits
---

Run a documentation correctness audit of this repository using the
`docs-correctness-audit` skill. Invoke that skill and follow it exactly:

1. Run its bundled `scripts/collect-ground-truth.sh` once to gather the
    authoritative ground-truth bundle (flake outputs, recipes, scripts,
    workflows, ci.yml job list, lint-group membership, the valid CI job /
    check-name union allowlist, crons, required-check count, the
    ephemeral-token sweep, and the internal link / anchor check).
1. Fan out read-only cluster readers (one per doc cluster) checking factual
    drift, internal consistency, and prose quality.
1. Require a coverage note from every reader saying what it cross-checked
    against ground truth. A cluster reporting "clean" without one is not clean
    — re-dispatch it.
1. Verify every candidate finding empirically before reporting it — especially
    hand-written claims about CI jobs / required checks, which freshness gates do
    not cover.
1. Write a severity-ranked findings report to `.claude/reports/`.
1. Close by telling the user to record the audit point: the final fix PR runs
    `just docs-audit-done` and stages `.github/docs-audit-state`. This audit is
    read-only and cannot write that marker itself, and the monthly reminder
    measures drift pressure from it — an audit that never records its point
    leaves pressure climbing.

This is a READ-ONLY audit: do not edit any documentation in this pass. If the
user passed an argument naming a subset (e.g. a single cluster like
`security/`), scope the audit to that subset but keep the same method.

$ARGUMENTS
