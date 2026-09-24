---
name: docs-audit-fix
description: Fix pass for a docs-correctness-audit findings report — works the findings on a branch, records a paragraph ledger, runs a separate-agent gate, and opens the PR only when check-fix-ledger.sh passes. Invoke ONLY via the /docs-fix slash command. Do NOT auto-trigger on natural-language mentions of fixing docs or audit findings.
---

# Docs-audit fix pass

A findings report from `/docs-audit` is the input. The output is one PR
whose body shows, per rewritten paragraph, the artifact range it was
written against and the gate's verdict on it.

This phase exists because a fix pass reads the finding, not the audit's
rules. Across this repo's audit cycles, about half of an audit's findings
were defects the previous round's fix pass had written, and the share swung
widely from round to round. What caught them before merge was a second
reader aimed at the fix, holding the duties below. The contract makes that
reader's input complete; the checker proves it covers every changed
paragraph in its scope.

## The contract (the writer)

1. **Every rewritten paragraph names its artifact.** Record the file and
    line range of the code, workflow or script whose behaviour the new
    sentence claims. A sentence with no artifact behind it was inferred from
    the old sentence.
1. **A second reader re-reads the pairs** — not the writer. See the gate.
1. **A claim the audit found overbroad is dropped or scoped to the set it
    can defend, never re-sharpened; a plain wrong fact is corrected to the
    artifact's fact.** Replacing a vague claim with a precise wrong one is
    the most repeated defect these audits find. Record the shape: `drop`, `scope`, or `correct` (a fact
    replaced by the artifact's fact, no new boundary word).
1. **Clear the sibling set.** Name every other place the corrected claim
    lives (`git grep` the old wording across
    `'*.md' '.github/**' 'scripts/*.sh'`, each alternative its own `-e`)
    and record each member `changed`, `removed` (the text was deleted), or
    `unchanged` with the reason it is still true. The sweep's output is a
    list to clear, not a list to consider.
1. **A heuristic gets a negative fixture before it ships** — the input it
    must still reject, proven to fail when the rule is reverted.
1. **A filter that reshapes authored text is tested on the ordinary case**,
    not only the case that motivated it.

## Flow

1. Branch `docs/<topic>` from `main`. Work the findings.
1. For each rewritten paragraph, append a pair to
    `<report-stem>.ledger.json` beside the report. A `changed` or `removed`
    Markdown sibling is itself a rewritten paragraph: it needs a pair
    covering it, unless it shares its pair's paragraph or sits in the root
    `CHANGELOG.md` or `tests/fixtures/`. A `removed` sibling in a file the
    branch deletes needs only that file's `code_changes` entry.
    For each changed file that is not a surviving Markdown file (a deleted
    `.md` file included), append a `code_changes` entry with the evidence
    (test, harness, mutation) that it is right. Commit as you go; the
    checker reads commits, not the working tree.
1. **Gate.** Dispatch one agent that did not write the changes, on the
    strongest model available, with the ledger path, the diff command
    (`git diff main...HEAD`), and the gate duties below verbatim. It writes
    `<report-stem>.gate.json` and nothing else.
1. For every FALSE or OVERREACHES: fix it, update the ledger, commit, and
    re-dispatch the gate on the changed pairs only. A pair's verdict is tied
    to its paragraph's text by hash, and a code change's attack to the blob
    it attacked, so anything fixed after the gate is stale until the gate
    reads it again. Review the fix, not only the thing being fixed.
1. Run `.claude/skills/docs-audit-fix/scripts/check-fix-ledger.sh <ledger> <gate>` until it exits 0. Also run the lints and harnesses the diff touches,
    and every `refresh-*.sh` whose output the diff touches.
1. Open the PR (`gh pr create --head <branch>`). The body carries the pair
    table rendered from the ledger and gate — one row per pair: paragraph
    `file:lines`, artifact `file:lines`, fix shape, siblings
    (changed/removed/unchanged counts), verdict — plus each code change's
    attack and result, and the checker's OK line.
1. If the report said this audit closes the cycle, the PR's last commit is
    `just docs-audit-done`. If another audit will read these fixes, do not
    run it.

## The gate's duties

The gate is a separate agent. It did not write the changes.

1. **Artifact first, paragraph second.** Open the artifact range, form a
    view of what it does, then read the paragraph.
1. **Verdict per pair:** `TRUE`, `FALSE`, or `OVERREACHES` (true of part of
    the artifact, stated of all of it), with a one-line note for anything
    but TRUE.
1. **Fix shape.** Check the recorded shape against the diff: a `drop` or
    `scope` that introduced a new boundary word (`only`, `every`, `never`, a
    count) is a re-sharpening and is OVERREACHES.
1. **Sibling set, per member.** Re-run the twin sweep yourself. A member
    the ledger omits, or marks unchanged for a reason that is false, makes
    the pair FALSE.
1. **Attack every changed matcher, parser or generator.** For each
    `code_changes` entry, construct inputs meant to break it — boundaries,
    empty input, the ordinary case next to the motivating one — and run
    them. Record `attack` (what you ran) and `result` (what happened).
    Confirming the named case works is not an attack.

For each pair record the hash of the paragraph as you read it:
`check-fix-ledger.sh --hash <file> <start>-<end>`. For each code change
record the blob you attacked: `git rev-parse HEAD:<file>`, or `deleted`
for a file the branch removes.

## Files

`<report-stem>.ledger.json` (writer):

```json
{
  "report": "<report path>",
  "pairs": [
    {
      "id": "p1",
      "finding": 3,
      "file": "docs/security/trust-model.md",
      "lines": "40-46",
      "artifact": [{"file": "scripts/check-egress-allowlist.sh", "lines": "110-131"}],
      "fix_shape": "scope",
      "siblings": [
        {"file": "docs/invariant-index.md", "lines": "88-88", "status": "changed"},
        {"file": "docs/architecture/ci.md", "lines": "212-212", "status": "removed"},
        {"file": "SECURITY.md", "lines": "12-14", "status": "unchanged",
          "reason": "states the other arm, true as written"}
      ]
    },
    {
      "id": "p2",
      "finding": 3,
      "file": "docs/invariant-index.md",
      "lines": "88-88",
      "artifact": [{"file": "scripts/check-egress-allowlist.sh", "lines": "110-131"}],
      "fix_shape": "scope",
      "siblings": []
    },
    {
      "id": "p3",
      "finding": 3,
      "file": "docs/architecture/ci.md",
      "lines": "212-212",
      "artifact": [{"file": "scripts/check-egress-allowlist.sh", "lines": "110-131"}],
      "fix_shape": "drop",
      "siblings": []
    }
  ],
  "code_changes": [{"file": "scripts/check-egress-allowlist.sh", "evidence": "harness scenario X"}]
}
```

`lines` is `<start>-<end>` at `HEAD`. A `removed` sibling's `lines` is the
head-side position its deleted text sat at — for a pure deletion, the line
before it, the line after it, or both. Here `p3` pairs the paragraph that
follows the deleted one, where the deletion anchors.

`<report-stem>.gate.json` (gate only):

```json
{
  "pairs": [
    {"id": "p1", "verdict": "TRUE", "hash": "<from --hash>", "note": ""},
    {"id": "p2", "verdict": "TRUE", "hash": "<from --hash>", "note": ""},
    {"id": "p3", "verdict": "TRUE", "hash": "<from --hash>", "note": ""}
  ],
  "code_changes": [
    {"file": "scripts/check-egress-allowlist.sh", "blob": "<from git rev-parse>",
      "attack": "empty allowlist; host with trailing dot", "result": "exit 1 naming the host"}
  ]
}
```

Both stay untracked in `.claude/reports/`. Only the PR body is durable.

## What the checker proves, and what it does not

It reads the committed diff from the merge base with `main` (`--base`
overrides) to `HEAD`, refuses to run over uncommitted tracked changes, and
ignores the caller's diff configuration (external diff, textconv, header
prefixes, `diff.algorithm` and the indent heuristic,
`diff.ignoreSubmodules`, pathspec variables, replace refs). It exits 0 when every check below
passes, 1 with one `check-fix-ledger: <class>: <detail>` line per finding,
and 2 when it cannot run.

- **Shape.** The ledger and the gate each hold exactly one JSON object;
    every list element is an object; every pair and artifact range is
    `<start>-<end>` with at most six digits a side (a `changed` or `removed`
    sibling's range is checked with the siblings; an `unchanged` sibling's
    `lines` is not checked); no ledger file name holds a newline, tab or CR;
    pair ids and verdict ids are unique, every verdict names a ledger pair,
    and every gate code change carries a `blob` that is an object id or
    `deleted`. A `schema` finding from this shape pass stops the checks
    below; the later checks also report some tracking and range faults as
    `schema`, and those stop nothing.
- **Completeness.** Every changed Markdown hunk is covered, except in
    the root `CHANGELOG.md` and `tests/fixtures/`, inside a generated `BEGIN/END`
    block of the same name on both sides, or a pure re-wrap. Covered means
    every non-blank paragraph the hunk's new side touches overlaps a pair's
    paragraph, each needing its own pair. Every other changed file, a deleted
    Markdown file included, is listed in `code_changes`.
- **Artifacts and pairs** name files tracked at `HEAD`, with the range
    inside the file.
- **Siblings.** An `unchanged` one names a file tracked at `HEAD` and a
    reason that is not blank. A `changed` one lies inside its file and inside
    one paragraph, clear of its own pair's recorded lines, and a covered hunk
    adds a line inside it whose whitespace-collapsed text matches no removed
    line of that hunk. A `removed` one spans at most two lines, may sit one
    past the end of the file, stays clear of its own pair's recorded lines,
    and is touched by a covered hunk that removes a line whose collapsed text
    matches no added line of that hunk. That hunk's reach is the line before
    and after a pure deletion, its new lines plus the next one when it
    removes more lines than it adds, and its new lines otherwise. A
    `removed` one in a file the diff deletes, tracked at the merge base and
    absent at `HEAD`, needs only a well-formed range of at most two lines,
    with no hunk. In a file
    that is not Markdown, or in the root `CHANGELOG.md` or `tests/fixtures/`,
    any hunk touching the range clears a `changed` or `removed` sibling, a
    whitespace-only edit included.
- **Verdicts.** Every pair is gated `TRUE` with a hash equal to its
    paragraph's hash now: the whole blank-line-delimited block, whitespace
    collapsed, so a re-wrap or a line shift keeps the verdict current and any
    word change makes it stale. Every code change has a gate entry whose
    `attack` and `result` are not blank and whose `blob` is the one the file
    holds at `HEAD` (or `deleted` when it is absent); a mismatch is
    `stale-attack`.

Finding classes: `schema`, `enum`, `artifact`, `uncovered-hunk`,
`uncovered-file`, `sibling-untracked`, `sibling-reason`,
`sibling-not-changed`, `sibling-not-removed`, `missing-verdict`, `verdict`,
`missing-hash`, `stale-verdict`, `missing-attack`, `stale-attack`. On success it prints one
OK line with the pair, hunk (covered, reflow-only, generated), code-change
and sibling (changed, unchanged, removed) tallies; the PR body quotes it.

It does not judge whether a sentence is true or re-sharpened — that is
the gate's job. Its known limits:

- The substance tests compare lines, not words. A line split or join, a
    manual re-wrap, or a moved line can read as a change.
- A `removed` sibling is judged per hunk, so it reaches one line past any
    hunk that deletes more lines than it adds, wherever in the hunk the
    deletion sat. An in-place edit counts: a removed line whose text changed
    is a deletion, so a `removed` sibling on an edited line passes.
- Prose in script comments and workflow bodies is covered per file through
    `code_changes`, not per paragraph.
- The root `CHANGELOG.md` and `tests/fixtures/` are outside the paragraph
    check: no pair or `code_changes` entry is required for their Markdown
    hunks.
- Siblings outside in-scope Markdown are cleared by any touching hunk, as
    **Siblings** above says, so a whitespace-only edit clears them.
- A pure deletion anchors at the lines either side of it. When a whole
    paragraph goes, that is its blank line and the next paragraph, so the
    pair usually goes on the paragraph that follows.
