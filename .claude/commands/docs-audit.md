---
description: Read-only documentation correctness audit — severity-ranked findings report, no edits
---

Run a documentation correctness audit of this repository using the
`docs-correctness-audit` skill. Invoke that skill and follow it exactly:

1. Read the skill's `references/repo-map.md` in full before dispatching
    anything.
1. Aim first at prose the last fix pass touched: read `LAST_AUDIT_SHA` from
    `.github/docs-audit-state` and list tracked prose changed since —
    Markdown, workflow bodies and script-composed bodies alike — then
    hand the readers that file list as a priority set — not a scope limit.
    List the window's merges too, unpathed, and read the newest merge's
    paragraphs first; mid-cycle, when the marker has not moved, the
    bundle's `PASS ATTRIBUTION` section is that listing with the files
    each commit touched, and the priority set comes from it.
    The bundle's `PROSE HOTSPOTS` ranking names the lines recent fix passes
    rewrote; readers take the whole paragraph around each, not the hunk.
1. Run the collector bundled with that skill (`<skill-dir>/scripts/collect-ground-truth.sh`,
    resolved from the SKILL.md's own directory) once to gather the
    authoritative ground-truth bundle (the prose-hotspot ranking, the
    pass-attribution listing, flake outputs, recipes, scripts, workflows,
    ci.yml job list, lint-group membership, the valid CI job / check-name union
    allowlist, crons, required-check count, the ephemeral-token sweep, and the
    internal link / anchor check). Save it under `.claude/reports/` and hand
    every reader that path together with one shared reader brief, rather than
    restating the method in each dispatch.
1. Fan out read-only cluster readers (one per doc cluster), overridden to the
    strongest model available, checking factual drift, internal consistency,
    and prose quality.
1. Require a coverage note from every reader saying what it cross-checked
    against ground truth, plus a `Could not locate` list of anything the
    dispatch named that the reader could not find. A cluster reporting "clean"
    without a coverage note is not clean — re-dispatch it.
1. Verify every candidate finding empirically before reporting it — especially
    hand-written claims about CI jobs / required checks, which freshness gates do
    not cover. Run any command a doc hands the reader and derive the same set
    a second way. Then `git grep` the wrong wording across all tracked prose
    (`'*.md' '.github/**' 'scripts/*.sh'`) so every twin joins the finding.
1. Write a severity-ranked findings report to `.claude/reports/` — taking
    the `-<n>` suffix the bundle and brief took — attributing each finding
    to the pass that wrote it where the bundle's `PASS ATTRIBUTION` section
    can say.
1. Close by saying whether this audit closes the cycle. If no further audit is
    planned, the final fix PR runs `just docs-audit-done` and commits the
    updated `.github/docs-audit-state` as its last commit; the monthly reminder
    measures drift pressure from that marker, so never recording it leaves
    pressure climbing. If another audit will read this cycle's fixes, say the
    fix PR does *not* run it — a mid-cycle marker drops unread commits out of
    the next priority set. Either way this audit is read-only and cannot write
    the marker itself.

This is a READ-ONLY audit: do not edit any documentation in this pass. If the
user passed an argument naming a subset (e.g. a single cluster like
`security/`), scope the audit to that subset but keep the same method.

$ARGUMENTS
