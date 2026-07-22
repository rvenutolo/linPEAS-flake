---
name: multi-agent-review
description: >-
  Multi-agent, refute-all code/infra review of this repo across 8 fixed
  dimensions (nix packaging, shell scripts, CI/supply-chain, docs, test
  harnesses, invariant↔enforcement, over-engineering, release-chain E2E). The
  user scopes each dimension interactively, then a per-dimension gated Workflow
  fan-out finds candidate issues and adversarially refutes them, emitting one
  severity-ranked report without editing anything. Invoke ONLY via the
  /repo-review slash command. Do NOT auto-trigger on natural-language mentions
  of reviews, audits, bugs, or "look over the code" — this skill runs on
  explicit request only.
user-invocable: false
---

# Multi-agent refute-all review

Review this repo across **8 fixed dimensions**, one gated `Workflow` fan-out
per dimension: parallel finder slices surface candidate findings, then
independent skeptics try to *refute* each one, and only survivors reach a
single severity-ranked report. **Read-only — no edits.** The deliverable is a
report the user triages later, written so any single finding could be lifted
into a GitHub issue without rework.

The 8 dimensions, their finder slices, per-dimension refuter guidance, and the
cross-dimension watch-outs are hardcoded (tuned for this repo) in
[`references/dimensions.md`](references/dimensions.md). Read it before scoping —
it is the source of truth for what each dimension covers.

## Why these disciplines matter

- **Refute-all is the verification — nothing reaches the report unrefuted.**
    Subagents reading code flag plausible-but-wrong issues. Every finding faces 3
    independent skeptics prompted to *refute it*, each defaulting to refuted
    unless it can reproduce the defect against the real artifact; keep the finding
    only if ≥2 of 3 fail to refute. This is what makes the report trustworthy, so
    never skip it, even under time pressure.
- **Empirical repro beats trace-reading — for both finders and refuters.** Code
    that looks broken in trace often works (and vice-versa). A finding must carry
    a concrete `failure_scenario` (inputs/state → wrong outcome) the refuters
    actually ran. A 30-second probe beats a confident wrong claim.
- **Report-only, mutate nothing.** Not even a generated file's mtime. If
    verifying a fact would write to the tree, inspect a read-only command's output
    or copy the artifact out. End the run by confirming `git status` shows no
    modified tracked files.
- **Per-dimension gates keep the user in control.** Each dimension runs only
    after the user says "go". Between gates, wait — no self-scheduled wakeups.
    This is a token-heavy flow; the user paces it.
- **Keep refuter verdict scope matched to the finder's question.** A
    "is-it-enforced" skeptic will wrongly kill a "is-it-buggy" finding. Scope each
    dimension's refuter prompt to that dimension's claim type (see the watch-outs
    in `references/dimensions.md`).

## Procedure

### 1. Scope the review with the user (`AskUserQuestion`)

Ask which dimensions to run and how deep. Batch into `AskUserQuestion` calls
(≤4 questions each). For each of the 8 dimensions offer **deep** (default) /
light / skip — except dimension 3 (**adversarial** default) and dimension 7
(**advisory** only). Also confirm the run-wide parameters, each with its
recommended default:

- **Verification:** refute-all (default) — never offer "skip refutation".
- **Output:** single report under `.claude/reports/` (default; no issues filed).
- **Pacing:** per-dimension gates (default) — user says "go" before each.

Bake the answers in. Do not re-ask a settled parameter per dimension.

### 2. Run each selected dimension as a gated `Workflow`

For each selected dimension, in order: **wait for the user's "go"**, then launch
one `Workflow` whose script is the pipeline in the template below. After it
returns, append its survivors to the running report and show the user a
one-screen summary (counts + top findings) before the next gate.

Seed later dimensions' finder prompts with earlier **confirmed** findings —
especially dimension 5 with dimensions 2 & 6 (a silent-pass bug is usually an
untested rejection path). Pass them in via the finder prompt text.

### 3. Workflow script template

One dimension = one `Workflow` call. Fan out the dimension's slices as finders;
each finding is refuted by 3 skeptics; keep ≥2/3 survivors. Adapt `SLICES` and
the prompts per dimension from `references/dimensions.md`. **No backticks inside
the template literals** (they break the JS parser — concatenate strings).

```javascript
export const meta = {
  name: 'review-dimension',
  description: 'Finder fan-out then 3-skeptic refute-all for one review dimension',
  phases: [{ title: 'Find' }, { title: 'Refute' }],
}
const FINDING = { /* JSON Schema: {findings:[{file,line,severity,claim,evidence,failure_scenario}]} */
  type: 'object',
  properties: { findings: { type: 'array', items: { type: 'object',
    properties: { file:{type:'string'}, line:{type:'integer'}, severity:{type:'string'},
      claim:{type:'string'}, evidence:{type:'string'}, failure_scenario:{type:'string'} },
    required: ['file','claim','failure_scenario'] } } },
  required: ['findings'],
}
const VERDICT = { type:'object',
  properties: { refuted:{type:'boolean'}, why:{type:'string'} },
  required: ['refuted'] }

// SLICES + the shared finder instruction come from references/dimensions.md,
// injected by the controller for the chosen dimension.
const results = await pipeline(
  SLICES,
  s => agent(FINDER_PROMPT(s), { label: 'find:' + s.key, phase: 'Find', schema: FINDING }),
  review => parallel((review.findings || []).map(f => () =>
    parallel([0,1,2].map(i => () =>
      agent('Try to REFUTE this finding. Default refuted=true unless you can '
        + 'reproduce the defect against the real file. Finding: ' + JSON.stringify(f),
        { label: 'refute:' + (f.file||'?'), phase: 'Refute', schema: VERDICT })))
      .then(vs => ({ f, survived: vs.filter(Boolean).filter(v => !v.refuted).length >= 2 }))))
)
return results.flat().filter(Boolean).filter(r => r.survived).map(r => r.f)
```

If a task-notification truncates, recover per-agent returns from the run's
`journal.jsonl` with `jq` rather than re-running.

### 4. Write / append the report

One artifact under `.claude/reports/` (never tracked `docs/`). Structure below.
After the last dimension, confirm `git status` shows no modified tracked files.

## Report structure

```text
# Multi-agent review — findings report

## Executive summary
<counts per dimension × severity; top findings priority-ordered, each a
  self-contained file:line + one-line claim>

## Dimension <n> — <name>
<slices run; how many raw findings the refute-all killed>
### <n>.<m> — <file:line> · <severity> · <title>
- Claim: …
- Evidence: <source of truth that proves it>
- Failure scenario: <inputs/state → wrong outcome, reproducible from here>
- Suggested direction: …

## Advisory (dimension 7)   <-- kept visually separate from defect sections>

## Refutation log
<per dimension: what was found-then-killed and why — shows the finder's
  false-positive rate, not just survivors>
```

Severity scale: `critical / high / medium / low / advisory`. Dimension 7
findings are always `advisory`. Rank findings most-severe-first within each
dimension. Every reported finding must be self-contained and carry its
`failure_scenario`.

## Spot-check protocol (offer to the user)

Pick any 3 confirmed findings, follow their file:line + failure scenario,
confirm reproducible. If a "confirmed" finding can't be reproduced, that
dimension's refute-all was too weak — re-run it stricter.
