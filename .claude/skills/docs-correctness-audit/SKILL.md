---
name: docs-correctness-audit
description: >-
  Read-only documentation correctness audit for this repo: cross-checks every
  tracked Markdown doc (README, docs/**, SECURITY, CONTRIBUTING,
  tests/README.md, the PR template, and the tracked `.claude/` tooling)
  against the actual code, CI, config, and workflows, then emits one
  severity-ranked findings report without editing anything. Invoke ONLY via the
  /docs-audit slash command. Do NOT auto-trigger on natural-language mentions of
  docs, reviews, audits, staleness, or "are the docs up to date" — this skill
  runs on explicit request only.
user-invocable: false
---

# Documentation correctness audit

Review every Markdown doc in this repo against the *actual* state of the code,
config, and CI, then emit one prioritized findings report. **The report stage is
read-only — no edits.** The point is to let the user triage before any churn.

This skill is tuned to this repo. Concrete ground-truth commands, the doc
cluster map, the generated-doc → generator table, and the ephemeral-token
regex live in [`references/repo-map.md`](references/repo-map.md). Read it before
dispatching — the audit shares those facts with every reader so cross-checks
agree on one source of truth.

## Why these disciplines matter

- **Report-first, no edits — read-only means do not even touch.** A 40+ file
    repo has many small drifts. Editing as you find churns the tree and buries the
    signal. A ranked report lets the human decide what to fix, in what order;
    fixing is a separate, later pass. Mutate *nothing* — not even a generated
    file's mtime. Running a generator or a build that rewrites a store-linked file
    counts as a mutation and is out of bounds. If verifying a fact would write to
    the tree, inspect a read-only command's output or copy the artifact out
    instead. End the run by confirming `git status` shows no modified tracked
    files.
- **Verify every finding empirically before reporting it.** Subagents reading
    prose will flag things that *look* wrong but are fine in reality (and miss
    things that look fine). Before a finding enters the report, the controller
    re-checks it against the real artifact — open the workflow and read the cron,
    run the command, grep for the symbol, count the items. Code that looks broken
    in trace often works; a 30-second probe beats a confident wrong "fix". Each
    reported finding must cite the source of truth that proves it.
- **Generated docs are CI-enforced — never flag their bodies.** Several docs are
    produced by `refresh-*.sh` generators and gated for freshness by CI. Their
    content is not authored prose; the generator is the source of truth. Flag only
    (a) hand-written prose *outside* the `BEGIN/END` generated markers, or (b) a
    real generator-vs-reality gap (rare; mark low-confidence). A fix to generated
    content means fixing the generator, not the doc — out of scope for the report stage.
- **"CI gates it" is NOT proof the prose is correct — this is the signature
    drift of this repo, so make it the spine of the audit.** Freshness checks
    (`*-fresh`) gate only the *generated block bodies*; they say nothing about
    hand-written prose that *describes* CI. The trap: many per-rule checks are
    **member checks** that run inside a group job — via `scripts/run-lint-group.sh`
    (`lint-workflow-security`, `lint-script-hygiene`, `lint-doc-invariants`,
    whose membership lives in `.github/lint-groups.yml`) or via
    `scripts/run-harness-group.sh` (`harness-group`, whose members are the test
    harnesses listed in that script's own `HARNESSES` array) — not standalone
    jobs and not required status checks. Prose
    that calls such a member a "required CI job" is real drift that *no* freshness
    gate catches, because nothing generates that sentence. Two failure modes,
    both high severity: (a) **mislabel** — a real lint-group *member* called a
    standalone "required CI job"; (b) **ghost** — a doc names a "CI job" / "required
    check" that exists in *no* workflow and *no* lint group at all. Catch both by
    checking every hand-written job / required-check / check name against the
    collector's **VALID CI JOB / CHECK NAMES** union allowlist (every workflow job
    id + every lint-group member): a name absent from that list is a ghost; a name
    present only as a lint-group member but called a standalone job is a mislabel.
    Do this *even when every freshness check is green* — a green pipeline beside a
    sentence naming a job that doesn't exist is exactly what this audit surfaces.
- **Ephemeral references rot.** This repo bans dates, PR/issue numbers, planning
    labels, and causal-history phrasing in tracked docs (the rationale: tracked
    files describe the *current* state; history lives in git). Flag violations of
    the banned-token regex in `references/repo-map.md`.

## Procedure

### 1. Collect ground truth once

Run the bundled collector once and keep its output. It lives in this skill's
own `scripts/` directory — resolve its absolute path from the directory of the
SKILL.md you were given, then run it from the repo root:

```sh
bash <this-skill-dir>/scripts/collect-ground-truth.sh
```

It emits one labeled bundle of eleven sections — flake outputs, `just` recipes,
the `scripts/` inventory (entry points *and* the `scripts/lib/` libraries they
source), workflows, the **ci.yml top-level job list**, **lint-group
membership**, the **`VALID CI JOB / CHECK NAMES`** union allowlist (the
ghost/mislabel detector this audit turns on), workflow crons, the required-check
context count, an **`EPHEMERAL-TOKEN HITS`** sweep of banned token shapes over
tracked docs, and an **`UNRESOLVED INTERNAL LINKS / ANCHORS`** check via
`lychee --offline`. Hand this same bundle to every reader
so a path/recipe/output/job/cron named in a doc is checked against one
authoritative list, not re-derived per agent (and not re-run by all of them).
`references/repo-map.md` explains what each field means and how to use it; the
collector is its executable form.

### 2. Fan out read-only readers, one per doc cluster

Dispatch parallel **read-only Explore agents** (they cannot edit — that
enforces the no-edits rule), one per cluster from the cluster map. Give each
agent: the ground-truth bundle, the three dimensions below, the generated-doc
exclusion list, and the ephemeral-token regex. Each returns structured findings
**plus a coverage note**: which hand-written claims in its cluster it
cross-checked against ground truth, and what it confirmed clean versus left
uncertain. A reader may not report a cluster "clean" merely because the
freshness checks pass — only after it has read the cluster's prose claims
against ground truth. It does not write files.

Read-only fan-out needs no orchestration opt-in — it is plain parallel reads.

### 3. Each reader checks three dimensions

1. **Factual drift (exhaustive).** Extract *every* concrete reference in the
    doc — file paths, flake outputs, `just` recipes, `scripts/*.sh` and the
    `scripts/lib/*.sh` libraries they source, shell
    commands, env vars, secret names, workflow/job names, config options,
    internal links/anchors — and verify each exists / is described correctly
    against ground truth and the real files. A doc naming a removed
    script/check/command, or describing a workflow that no longer matches its
    YAML, is high severity. Job names, required-check names, and phrasings like
    "required CI job X" are first-class references here — apply the CI-prose
    discipline above (member-vs-standalone is real drift, not pedantry).
    Internal link and heading-anchor resolution is given authoritatively by the
    collector's **`UNRESOLVED INTERNAL LINKS / ANCHORS`** section — flag every
    listed entry as high severity; do not re-derive by running lychee again.
1. **Internal consistency.** Docs contradicting each other (same fact stated two
    ways); invariant-index entries vs their tracked-doc sections; a claimed
    invariant with no backing check.
1. **Prose quality.** Clarity, grammar, dead links, and ephemeral-token
    violations per the regex. CHANGELOG / releases pages are exempt from
    every ephemeral class, not just the PR-ref and date bans — the lint
    skips both files wholesale (they structurally list PRs and dates).
    Ephemeral-token candidates come from the collector's
    **`EPHEMERAL-TOKEN HITS`** section (see `references/repo-map.md` §4 for
    suppression and scope). That sweep reads prose only — fenced blocks,
    generated bodies, and inline code spans are blanked first — but it is
    **not** the authority: `scripts/check-ephemeral-refs.sh` is. Run the real
    lint; anything the sweep reports that the lint does not is a false
    positive, and a doc that quotes a banned shape as an example is
    documentation, not a violation. Note `causal-history` is advisory-only even
    in the real lint, so a hit there is a style nit rather than a gate failure
    — report it as low severity if at all.

### 4. Controller verifies, completeness-gates, dedups, ranks

**Completeness gate first.** A cluster is "clean" only if its coverage note
shows *what* was cross-checked against ground truth — not that freshness checks
passed. A clean verdict with no coverage note is not clean; re-dispatch that
cluster to read its CI/job/required-check prose against the `ci.yml` job list.
Under-inspection that concludes "all good" is the failure mode this audit most
needs to prevent: a from-scratch reviewer will out-find a reader who trusts the
green pipeline.

Then, for each candidate finding, re-verify empirically (load-bearing discipline
above) and drop false positives. **Group by root cause, not by location.** The
same defect scattered across many files (e.g. one wrong enforcement-model phrase
repeated in a dozen lines) is *one* finding with a shared fix — state the root
cause once, list every affected `file:line`, and give the single fix pattern.
Reporting it as a dozen separate findings buries the signal and inflates the
count; collapsing it is what makes the report actionable in one pass. Then rank
by severity:

- **high** — a wrong or broken fact: dead link, wrong command/path/flag, a
    drifted CI/cron/config value, a claimed-but-absent check or script.
- **med** — an internal contradiction, or an ephemeral-token violation.
- **low** — prose / clarity / minor wording.

### 5. Write the report (no edits)

Write one report to `.claude/reports/<YYYY-MM-DD>-docs-correctness-findings.md`
using the template below. Stop there. Do not edit any doc. Surface, in the
report's closing notes, anything that needs a human decision (spec ambiguity,
a generated-doc/generator fix, a finding whose "fix" would change runtime
behavior).

### 6. Tell the user to record the audit point

Close the report by naming the step that ends the cycle: once these findings
are fixed, the final fix PR runs `just docs-audit-done` and stages
`.github/docs-audit-state`. That marker is the base the monthly reminder
measures drift pressure from, so an audit that never records its point leaves
pressure climbing and the reminder issue open. Say it explicitly — this skill
is read-only and cannot write the marker itself.

If the audit found nothing, the instruction is the same and applies
immediately: a clean read is still a read.

## Report structure

Use this template:

```markdown
# Docs correctness sweep — findings report

**Date:** <YYYY-MM-DD>
**Phase:** 1 (report only — no edits applied)
**Scope:** <N files>
**Method:** parallel read-only audits per cluster; every finding re-verified
empirically against the real artifact before inclusion.

## Severity index
| # | Severity | File:line | Dim | One-liner |
|---|----------|-----------|-----|-----------|
| 1 | HIGH | path:line | drift | ... |
...

If several index rows share one root cause, say so in a line right under the
table ("Findings 1–6 are one defect: …") so the reader fixes the pattern once.

## Cluster coverage
One row per cluster, so a "clean" verdict is auditable — a cluster with no
findings must still show what was cross-checked, not just "clean".

| Cluster | Cross-checked | Findings | Notes |
|---------|---------------|----------|-------|
| security | job/check names vs ci.yml job list, required checks vs ruleset, links | 2 | ... |
| ... | ... | ... | ... |

## HIGH
### <n>. <file:line> — <title>
<what's wrong> · <the ground-truth proof> · **Fix:** <proposed fix>

## MED
...

## LOW
...

## Notes for the fix pass
- <batching suggestion, decisions the user must make, generated-doc/generator fixes>
```

Each finding states the file:line, the dimension, what is wrong, the *evidence*
(the command output or file line that proves it), and a proposed fix. Group by
severity; lead with the severity index so the report is skimmable.
