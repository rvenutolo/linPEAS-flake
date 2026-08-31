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
    Subagents reading code flag plausible-but-wrong issues. Every finding — up to the per-dimension refutation cap, the top 25 by
    severity — faces 3 independent skeptics prompted to *refute it*, each defaulting to refuted
    unless it can reproduce the defect against the real artifact; keep the finding
    only if at least two of the skeptics that returned fail to refute. This is what makes the report trustworthy, so
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
one `Workflow` whose script is the template below. It returns
`{ survivors, refuted }`: append `survivors` to the running report's dimension
section and fold `refuted`'s unanimous kills into the Refutation log (the killed findings *are*
the finder false-positive rate — dropping them leaves that section empty). Each
`refuted` entry carries `contested` — a `true` there means exactly one live
skeptic could not refute it, so a real finding may have been buried. Surface
those in a **Contested kills** subsection, never silently. Then show the user a
one-screen summary (counts + top findings, contested-kill count called out)
before the next gate. If the run logged a refutation cap, state
`<n> of <m> deduped findings sent to refute-all (cap <n>)` in that dimension's report section
and in the gate summary — findings past the cap reach neither survivors
nor the refutation log, so an unstated cap silently under-reports.

Seed later dimensions' finders with earlier **confirmed** findings — especially
dimension 5 with dimensions 2 & 6 (a silent-pass bug is usually an untested
rejection path). Inject them via the template's `SEED_FINDINGS` slot, not by
hand-editing each finder prompt.

### 3. Workflow script template

One dimension = one `Workflow` call. Fan out the dimension's slices as finders,
dedup, then refute each survivor with 3 skeptics; keep a finding when at least
two of the skeptics that returned could not refute it. The controller
injects four per-dimension values: `SLICES` and `REFUTER_GUIDANCE` come from
`references/dimensions.md` (the refuter paragraph is injected *verbatim* — this
is what scopes the skeptic to the dimension's claim type); `FINDER_PROMPT(s)` is
composed by the controller from the dimension's Slices and hunt guidance; and
`SEED_FINDINGS` is earlier confirmed findings as text, or `''`. **No backticks
inside JS template literals in the script you compose** (they break
parsing — use string concatenation).

```javascript
export const meta = {
  name: 'review-dimension',
  description: 'Finder fan-out, dedup, then 3-skeptic refute-all for one dimension',
  phases: [{ title: 'Find' }, { title: 'Refute' }],
}
// severity is an enum so the report's ranking scale is honest at the schema layer.
const FINDING = {
  type: 'object',
  properties: { findings: { type: 'array', items: { type: 'object',
    properties: { file:{type:'string'}, line:{type:'integer'},
      severity:{type:'string', enum:['critical','high','medium','low','advisory']},
      claim:{type:'string'}, evidence:{type:'string'}, failure_scenario:{type:'string'} },
    required: ['file','claim','failure_scenario'] } } },
  required: ['findings'],
}
const VERDICT = { type:'object',
  properties: { refuted:{type:'boolean'}, why:{type:'string'} },
  required: ['refuted'] }

// Barrier, not pipeline: dedup every slice's findings BEFORE the expensive refute
// fan-out, so one file:line is not independently refuted by three skeptics twice.
const found = await parallel(SLICES.map(s => () =>
  agent(FINDER_PROMPT(s) + SEED_FINDINGS, { label: 'find:' + s.key, phase: 'Find', schema: FINDING })))
const seen = new Set()
const deduped = found.filter(Boolean).flatMap(r => r.findings || []).filter(f => {
  const key = (f.file || '?') + ':' + (f.line || '') + ':' + (f.claim || '').slice(0, 40)
  return seen.has(key) ? false : (seen.add(key), true)
})
const RANK = { critical: 0, high: 1, medium: 2, low: 3, advisory: 4 }
deduped.sort((a, b) => (RANK[a.severity] ?? 5) - (RANK[b.severity] ?? 5))
const CAP = 25
const toRefute = deduped.slice(0, CAP)
if (deduped.length > CAP) log('capped: refuting top ' + CAP + ' of ' + deduped.length + ' deduped findings (most-severe first)')

// REFUTER_GUIDANCE scopes the skeptic to this dimension's claim type — an
// is-it-enforced skeptic would wrongly kill an is-it-buggy finding.
const graded = (await parallel(toRefute.map(f => () =>
  parallel([0,1,2].map(i => () =>
    agent('You may run read-only commands to reproduce (nix eval/build, run the script '
      + 'against a crafted input, git show) but MUST NOT modify the tree. ' + REFUTER_GUIDANCE
      + ' Default refuted=true unless you reproduce the defect against the real artifact. '
      + 'Finding: ' + JSON.stringify(f),
      { label: 'refute:' + (f.file || '?'), phase: 'Refute', schema: VERDICT })))
    .then(vs => {
      const live = vs.filter(Boolean)
      const nonRefuted = live.filter(v => !v.refuted).length
      // contested = killed (< 2 skeptics failed to refute) but NOT unanimous: at
      // least one skeptic could not refute it. Such a kill can bury a real finding,
      // so it is surfaced separately rather than dropped silently.
      return { f, survived: nonRefuted >= 2, contested: nonRefuted === 1,
        votes: { nonRefuted, total: live.length }, why: live.map(v => v.why).filter(Boolean) }
    })))).filter(Boolean)

// Keep the killed findings — the Refutation log needs the false-positive rate,
// and contested kills must be visible, not silently dropped.
return {
  survivors: graded.filter(r => r.survived).map(r => r.f),
  refuted: graded.filter(r => !r.survived).map(r => ({
    finding: r.f, contested: r.contested, votes: r.votes, why: r.why })),
}
```

If a task-notification truncates, recover per-agent returns from the run's
`journal.jsonl` with `jq` rather than re-running.

### 4. Write / append the report

One artifact at `.claude/reports/<YYYY-MM-DD>-multi-agent-review-findings.md`
(never tracked `docs/`). Structure below.
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

## Advisory (dimension 7)   <kept visually separate from defect sections>

## Refutation log
<per dimension: what was found-then-killed and why — shows the finder's
  false-positive rate, not just survivors. Unanimous kills only
  (`nonRefuted === 0`); cite each entry's `votes` for the live skeptic count.>

### Contested kills
<killed findings where one skeptic could NOT refute (contested=true): each with
  its file:line, the dissenting skeptic's reason, and why the majority killed it.
  These are near-misses — a real finding may be buried here; do not omit them.>
```

Severity scale: `critical / high / medium / low / advisory`. Dimension 7
findings are always `advisory`. Rank findings most-severe-first within each
dimension. Every reported finding must be self-contained and carry its
`failure_scenario`. A `refuted` entry with `contested: true` is a kill that one
live skeptic could not refute — list it under **Contested kills**, never fold it
silently into the clean-kill log. The tallies are computed over the skeptics
that actually returned (`live`), so a run where one agent dies reports two
votes, not three; quote `votes` rather than assuming a denominator. A
`votes.total` of 0 (every skeptic died) is a non-verdict, not a kill — the
template still files it under `refuted` (zero non-refuting votes reads as a
unanimous kill), so check `votes.total` before logging and re-refute that
finding instead.

## Spot-check protocol (offer to the user)

Pick any 3 confirmed findings, follow their file:line + failure scenario,
confirm reproducible. If a "confirmed" finding can't be reproduced, that
dimension's refute-all was too weak — re-run it stricter.
