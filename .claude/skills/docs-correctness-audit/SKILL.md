---
name: docs-correctness-audit
description: >-
  Read-only documentation correctness audit for this repo: cross-checks every
  tracked Markdown doc (README, docs/**, SECURITY, CONTRIBUTING,
  tests/README.md, the PR template, CHANGELOG (verify-only), and the tracked
  `.claude/` tooling) plus the issue-body prose workflows write and the
  issue-template prompts
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

Documentation here is a function, not a file extension. Prose a workflow writes
into an issue it files — the triage steps and reason names in a notify body —
and the prompts in `.github/ISSUE_TEMPLATE/*.yml` are read by a human at the
moment they act on it, restate mechanisms the runbooks document, and drift the
same way a runbook does. They are in scope for the factual-drift dimension, and
a mismatch between such a body and the runbook it mirrors is one finding with
two sites, not one per file. `references/repo-map.md` §2 says how to enumerate
them and which reader owns them. Everything else outside tracked Markdown —
code comments, script `@description` blocks, workflow logic itself — stays out.

This skill is tuned to this repo. Concrete ground-truth commands, the doc
cluster map, the generated-doc → generator table, and the ephemeral-token
regex live in [`references/repo-map.md`](references/repo-map.md). Read it before
dispatching — the audit shares those facts with every reader so cross-checks
agree on one source of truth.

## Why these disciplines matter

- **Report-first, no edits — read-only means do not even touch.** A repo this
    size has many small drifts. Editing as you find churns the tree and buries the
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
    produced by generators (mostly `refresh-*.sh`) and, except where the table in
    `references/repo-map.md` §3 says otherwise, gated for freshness by CI. Their
    content is not authored prose; the generator is the source of truth. Flag only
    (a) hand-written prose *outside* the `BEGIN/END` generated markers — for the
    whole-file rows in `references/repo-map.md` §3 there is none — or (b) a
    real generator-vs-reality gap (rare; mark low-confidence). Applying a fix to
    generated content means fixing the generator, not the doc — report the gap,
    but edit nothing during the report stage.
- **"CI gates it" is NOT proof the prose is correct — this is the signature
    drift of this repo, so make it the spine of the audit.** Freshness checks
    (`*-fresh`) gate only the *generated bodies*; they say nothing about
    hand-written prose that *describes* CI. The trap: many per-rule checks are
    **member checks** that run inside a group job — via `scripts/run-lint-group.sh`
    (`lint-workflow-security`, `lint-script-hygiene`, `lint-doc-invariants`,
    whose membership lives in `.github/lint-groups.yml`) or via
    `scripts/run-harness-group.sh` (`harness-group`, whose members are the test
    harnesses listed in that script's own `HARNESSES` array) — not standalone
    jobs and not required status checks. Prose that calls such a member a
    "required CI job" is real drift that *no* freshness gate catches, because
    nothing generates that sentence. Two failure modes,
    both high severity: (a) **mislabel** — a real lint-group *member* called a
    standalone "required CI job"; (b) **ghost** — a doc names a "CI job" / "required
    check" that exists in *no* workflow and *no* lint group at all. Catch both by
    checking every hand-written job / required-check / check name against the
    collector's **VALID CI JOB / CHECK NAMES** union allowlist (every workflow job
    id + every lint-group member + every harness-group member): a name absent from
    that list is a ghost; a name present only as a lint-group or harness-group
    member but called a standalone job is a mislabel. Do this *even when every
    freshness check is green* — a green pipeline beside a sentence naming a job
    that doesn't exist is exactly what this audit surfaces.
- **Exclusive quantifiers are claims — check them like paths.** Words that
    assert a boundary — `only`, `always`, `never`, `every`, `the one` — and bare
    counts (`two X`, `three Y`) are as checkable as a file path, and rot the
    same way: the sentence stays put while the set it
    quantifies grows. They also have a self-inflicted variant. A fix pass
    correcting a too-narrow claim routinely overshoots into a false exclusive,
    so prose that a previous audit cycle edited is where these cluster. Verify
    each quantifier against the enumeration it ranges over — the bundle's job
    list, a lint-group roster, a script's actual flags — and report the
    mismatch. Severity follows the size of the gap: flatly false is high, "true
    except for one member" is low. Propose fixes that *drop or scope* the
    quantifier rather than sharpen it; a sentence that needs an exact count to
    stay true will drift again.
- **Ephemeral references rot.** This repo bans dates, PR/issue numbers, planning
    labels, review-pass labels and literal `.claude/` paths, and warns on
    causal-history phrasing in tracked docs (the rationale: tracked
    files describe the *current* state; history lives in git). Flag violations of
    the banned-token regex in `references/repo-map.md`.

## Procedure

### 0. Aim first at prose the last fix pass touched

`.github/docs-audit-state` records `LAST_AUDIT_SHA` — the commit the previous
cycle audited, once that cycle's fixes had landed. Read it, then list what has
changed in tracked prose since:

```sh
sha="$(sed -n 's/^LAST_AUDIT_SHA=//p' .github/docs-audit-state)"
git log --oneline --no-merges "${sha}..HEAD" -- '*.md' '.github/**' 'scripts/*.sh'
git diff --stat "${sha}..HEAD" -- '*.md' '.github/**' 'scripts/*.sh'
```

The pathspecs are the same three the twin sweep below uses: `'*.md'`
alone misses a pass that touched only a notify body in a workflow or a
body a script composes, and such passes land here.

Hand that file list to the readers as a **priority set, not a scope limit** —
every tracked doc is still in scope. Prose rewritten by an earlier cycle's fix
commits is the highest-yield place to look, because nothing gates a prose fix:
it is written against the one sentence being corrected, not against the
paragraph, the sibling docs, or the code a second time. Read those hunks
(`git show <sha>`) against the artifact they describe, never against the
sentence they replaced — a fix that swapped one wrong claim for another reads
as an improvement in the diff. If the state file is absent or its sha is
unreachable, record that in the report and audit everything at equal priority.

`LAST_AUDIT_SHA` moves once per *cycle*, not once per audit. Both the priority
set above and the collector's line window run from a marker to `HEAD`, so when
several audits run back to back — each iteration's fixes landing before the
next starts — they already reach what earlier iterations changed. What neither
does is single any one of those commits out: the ranking scores whole files
across the window, so the commit whose paragraphs have been checked least, the
one that landed last, carries no more weight than the rest of the cycle. The
first command above already lists them newest-first; list the window's merges
yourself, with the same `sha`:

```sh
git log --oneline --merges "${sha}..HEAD"
```

Read the newest commit's paragraphs before anything else. Filter by path,
not by subject: prose passes here land under `fix:` as readily as `docs:`.
This command lists every merge in the window: the PR-titled entries
are the passes that carried those commits — this repo merges every PR with
one — and `Merge branch 'main' into …` entries are branch syncs to skip.
Leave it unpathed; with a pathspec, history simplification drops PR merges
that carried prose. A merge is read with
`git show -m --first-parent <merge-sha>`; a bare `git show` on a merge
prints no hunks at all.

**The unit of re-reading is the paragraph, not the hunk.** A changed line is
where the last pass aimed; the defect that survived is beside it. Take each
hunk's whole paragraph — the full bullet, the full table row, the sentences
either side — and read every claim in it against the artifact, including the
clauses the diff never touched. Those clauses are the ones no pass has checked:
each fix pass read the sentence it came to correct and left its neighbours
carrying whatever they already said, so a false clause can sit untouched
through several cycles of edits to the text around it. When a paragraph
enumerates or bounds something — a list of what a layer catches, a set of
fields, two examples joined by "or" — resolve every member, not the one that
changed.

**Two defects the paragraph rule and the twin sweep both miss.** The paragraph
rule reaches what sits beside a rewrite; the twin sweep matches wording, so it
finds the same sentence wherever it sits. What neither reaches is the same
*subject* re-worded elsewhere in *this* file, and neither reads the
replacement wording as a pointer:

- **The distant same-file claim.** Changing what a section asserts obligates
    every other passage in that document on the same subject, however far away
    — a superseded bullet dozens of lines below a rewritten section, a signing
    or scoping claim hundreds of lines below under a different heading. Those
    passages are neither neighbours nor twins, so nothing else in this
    procedure sends a reader to them. After a rewrite, sweep the whole file for
    the *subject*, not for the wording that changed.
- **Deixis the rewrite invalidated.** Replacement wording carries pointers —
    `below`, `above`, `the following`, `listed here`, `which`, `it` — and a
    rewrite can leave them aimed at nothing: "every tool named below" when the
    list is inline in that same sentence, or an inserted parenthetical that
    detaches a relative clause from its referent. Resolve every pointer in a
    rewritten passage to the thing it names, and report the ones that land
    nowhere.

The collector's **`PROSE HOTSPOTS`** section ranks this for you: it scores each
doc by how many commits since an earlier audit point rewrote it and names the
lines the most recent cycle rewrote. A file high on that list with a rewritten line inside
a paragraph is the strongest aim point the bundle offers — repeated rewriting
means the paragraph keeps being read partially. Read those paragraphs whole,
first.

### 1. Collect ground truth once

Run the bundled collector once and keep its output. It lives in this skill's
own `scripts/` directory — resolve its absolute path from the directory of the
SKILL.md you were given, then run it from anywhere inside the repo checkout
(it resolves and cds to the repo root itself):

```sh
bash <this-skill-dir>/scripts/collect-ground-truth.sh
```

It emits one labeled bundle of twelve sections — a **`PROSE HOTSPOTS`**
ranking of the docs recent fix passes rewrote most, flake outputs, `just`
recipes, the `scripts/` inventory (entry points, the `scripts/lib/` libraries
they source, *and* the `scripts/*.awk` programs), workflows, the **ci.yml
top-level job list**, **lint-group membership**, the
**`VALID CI JOB / CHECK NAMES`** union allowlist (the ghost/mislabel detector
this audit turns on), workflow crons, the required-check context count, an
**`EPHEMERAL-TOKEN HITS`** sweep of banned token shapes over tracked docs, and
an **`UNRESOLVED INTERNAL LINKS / ANCHORS`** check via `lychee --offline`.
Hand this same bundle to every reader so a path/recipe/output/job/cron named
in a doc is checked against one authoritative list, not re-derived per agent
(and not re-run by all of them). `references/repo-map.md` explains what each
field means and how to use it; the collector is its executable form. If the
bundle comes back short — the ephemeral sweep fails loud on an unterminated
fence or generated block and aborts the collector inside its own section,
leaving that section a bare header and never starting the link check that
follows it — the malformed doc (named on stderr) is itself a high-severity
finding: record it, and treat both sections as unchecked rather than clean.

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
    doc — file paths, flake outputs, `just` recipes, `scripts/*.sh`, the
    `scripts/lib/*.sh` libraries they source, the `scripts/*.awk` programs, shell
    commands, env vars, secret names, workflow/job names, config options,
    internal links/anchors — and verify each exists / is described correctly
    against ground truth and the real files. A doc naming a removed
    script/check/command, or describing a workflow that no longer matches its
    YAML, is high severity. Job names, required-check names, and phrasings like
    "required CI job X" are first-class references here — apply the CI-prose
    discipline above (member-vs-standalone is real drift, not pedantry).
    Quantifiers (`only`, `always`, `never`, bare counts) are concrete
    references too, not softeners: resolve each against the set it ranges over,
    per the discipline above.
    Internal link and heading-anchor resolution is given authoritatively by the
    collector's **`UNRESOLVED INTERNAL LINKS / ANCHORS`** section — flag every
    listed entry as high severity; do not re-derive by running lychee again. A
    section reading `(lychee not found — …)`, `(lychee failed — …)` or
    `(lychee skipped N of M input(s) — …)` means the sweep is not clean — only
    `(none)` means every input was read. The skip marker reports
    independently, so it can head a real error list: when it does, both apply
    — flag the listed entries and record the sweep as incomplete. Say so in
    the coverage note.
1. **Internal consistency.** Docs contradicting each other (same fact stated two
    ways); invariant-index entries vs their tracked-doc sections; a claimed
    invariant with no backing check.
1. **Prose quality.** Clarity, grammar, dead links, and ephemeral-token
    violations per the regex. CHANGELOG / releases pages are exempt from
    every ephemeral class, not just the PR-ref and date bans — the lint
    skips both files wholesale (they structurally list PRs and dates).
    Ephemeral-token candidates come from the collector's
    **`EPHEMERAL-TOKEN HITS`** section (see `references/repo-map.md` §4 for
    suppression and scope). That sweep reads prose only — fenced blocks, then inline code
    spans, then generated bodies are blanked first — but it is
    **not** the authority: `scripts/check-ephemeral-refs.sh` is. Run the real
    lint; anything the sweep reports that the lint does not is a false
    positive, and a doc that quotes a banned shape as an example is
    documentation, not a violation. Note `causal-history` is advisory-only even
    in the real lint, so a hit there is a style nit rather than a gate failure
    — report it as low severity if at all.

### 4. Controller verifies, completeness-gates, dedups, ranks

**Completeness gate first.** A cluster is "clean" only if its coverage note
shows *what* was cross-checked against ground truth — not that freshness
checks passed. A clean verdict with no coverage note is not clean; re-dispatch
that cluster to read its CI/job/required-check prose against the collector's
**VALID CI JOB / CHECK NAMES** union allowlist. The union alone does not
attribute a name to its origin, and the bundle's `ci.yml` list covers one
workflow: settle member-vs-standalone by checking the name against the
bundle's **LINT-GROUP MEMBERSHIP** section and the `HARNESSES` array in
`scripts/run-harness-group.sh` versus the `jobs:` keys of every
`.github/workflows/*.yml` and `*.yaml` — a name found only in a group /
harness roster and in no workflow's `jobs:` block is the mislabel case. Under-inspection that
concludes "all good" is the failure mode this audit most needs to prevent: a
from-scratch reviewer will out-find a reader who trusts the green pipeline.

Then, for each candidate finding, re-verify empirically (load-bearing discipline
above) and drop false positives. **Group by root cause, not by location.** The
same defect scattered across many files (e.g. one wrong enforcement-model phrase
repeated in a dozen lines) is *one* finding with a shared fix — state the root
cause once, list every affected `file:line`, and give the single fix pattern.
Reporting it as a dozen separate findings buries the signal and inflates the
count; collapsing it is what makes the report actionable in one pass.

**Sweep for twins before writing the finding up — that is the controller's job,
not a reader's.** Grouping by root cause only collapses the sites somebody
found, and a reader works one cluster: it reports the instance in front of it
and never learns the same sentence was copied three docs away, sometimes inside
its own cluster. So for every confirmed finding, take the distinctive part of
the wrong claim and `git grep` it across all tracked prose before it enters the
report:

```sh
git grep -n 'distinctive phrase from the wrong claim' -- '*.md' '.github/**' 'scripts/*.sh'
```

The third pathspec is what reaches a `--body-file` body whose prose a
script composes; a body a `run:` step composes inline is already covered by
the `.github/**` pathspec.

Search the wrong wording, not the corrected one, and loosen the phrase until it
would catch a paraphrase — a twin rarely matches byte for byte. Every hit joins
that finding's site list. A finding that ships with one site when three exist
is not a smaller finding; it is a fix pass that will leave two wrong sentences
behind and hand them to the next cycle as fresh drift.

**A command a doc hands the reader is a claim about a set — run it.** Where
prose says "enumerate them with `<command>`", the command is as checkable as a
path, and it fails in a way reading cannot catch: it runs cleanly and returns a
subset, so the output looks like an answer. Run it, then derive the same set a
second way — a wider pattern, the other file shapes, the directory listing —
and diff the two. A command that silently misses a member of the set it claims
to produce is high severity, because every future reader trusts it instead of
looking.

Then rank by severity:

- **high** — a wrong or broken fact: dead link, wrong command/path/flag, a
    drifted CI/cron/config value, a claimed-but-absent check or script.
- **med** — an internal contradiction, or a *blocking-class* ephemeral-token
    violation (`RE_ISSUE`, `RE_DATE`, `RE_PLANNING`, `RE_REVIEW`, `RE_CLAUDE`).
    The `causal-history` class is advisory-only in the lint, and
    `ad-hoc-ticket` exists only in the collector sweep with no lint class at
    all — both are low at most.
- **low** — prose / clarity / minor wording.

### 5. Write the report (no edits)

Write one report to `.claude/reports/<YYYY-MM-DD>-docs-correctness-findings.md`
using the template below. Stop there. Do not edit any doc. Surface, in the
report's closing notes, anything that needs a human decision (spec ambiguity,
a generated-doc/generator fix, a finding whose "fix" would change runtime
behavior).

### 6. Tell the user to record the audit point

Close the report by naming the step that ends the cycle: once these findings
are fixed, the final fix PR runs `just docs-audit-done` and commits the
updated `.github/docs-audit-state`. That marker is the base the monthly reminder
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
**Stage:** report only — no edits applied
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
| security | job/check names vs the union allowlist, required checks vs ruleset, links | 2 | ... |
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
- Standing item: when a fix widens a claim that was too narrow, drop or scope
  the quantifier instead of sharpening it. Overshooting into a fresh false
  exclusive is a defect this repo's fix passes have repeatedly shipped.
```

Every finding on a quantifier carries its fix shape in the finding itself, not
only in the closing notes: state whether the proposed wording **drops** the
boundary word or **scopes** it to the set it can defend, and never propose a
replacement exclusive. A fix pass reading a per-finding instruction follows it;
one reading a single standing note at the end of the report has already written
the sentence. When the false claim was introduced by a previous cycle's fix —
`git log -L` or the hotspot ranking will say — record that in the finding. A
defect a fix pass manufactured is worth more than its severity suggests,
because it says the fix discipline itself is what leaked.

Each finding states the file:line (its dimension lives in the severity index),
what is wrong, the *evidence* (the command output or file line that proves
it), and a proposed fix. Group by severity; lead with the severity index so
the report is skimmable.
