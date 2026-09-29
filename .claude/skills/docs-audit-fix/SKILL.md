---
name: docs-audit-fix
description: Fix pass for a docs-correctness-audit findings report — works the findings on a branch, records a paragraph ledger, runs a separate-agent gate, and opens the PR only when check-fix-ledger.sh passes. Invoke ONLY via the /docs-fix slash command. Do NOT auto-trigger on natural-language mentions of fixing docs or audit findings.
---

# Docs-audit fix pass

A findings report from `/docs-audit` is the input. The output is one PR
whose body shows, per rewritten paragraph, the artifact it was
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
    sentence claims. When the fact lives outside the tree (a machine's
    config, a live service), record the command that shows it and what it
    printed instead. A sentence with no artifact behind it was inferred from
    the old sentence, and so was one whose artifact is another paragraph
    stating the same claim.
1. **A second reader re-reads the pairs** — not the writer. See the gate.
1. **A claim the audit found overbroad is dropped or scoped to the set it
    can defend, never re-sharpened; a plain wrong fact is corrected to the
    artifact's fact.** Replacing a claim with a differently wrong exclusive
    or a precise wrong fact is the most repeated defect these audits find.
    When the sentence says what a lint or matcher catches, point at the
    lint's own section instead of restating its conditions: a restated
    condition list reads as complete, which re-sharpens the claim.
    Record the shape: `drop`, `scope`, or `correct` (a fact replaced by the
    artifact's fact, no new boundary word).
1. **Clear the sibling set.** Name every other place the corrected claim
    lives: sweep the old wording with
    `.claude/skills/docs-audit-fix/scripts/check-fix-ledger.sh --sweep -- '<term>' …`,
    one term per alternative wording, and record the terms as the pair's
    `sweep`. Record each member `changed`, `removed` (the text was
    deleted), or `unchanged` with the reason it is still true. The sweep's
    output is a list to clear, not a list to consider, and the checker
    re-runs it: every hit must fall in the pair's paragraph or one of its
    siblings (see **Sweep** under what the checker proves).
1. **A heuristic gets a negative fixture before it ships** — the input it
    must still reject, proven to fail when the rule is reverted.
1. **A filter that reshapes authored text is tested on the ordinary case**,
    not only the case that motivated it.

## Flow

1. Branch `docs/<topic>` from `main`. Before editing, re-read each
    finding's cited site at the branch's `HEAD`: the report's line numbers
    come from the audit's commit, and `main` moves. A finding that no
    longer holds is listed as stale in the PR body, not fixed. Work the
    rest.
1. For each rewritten paragraph, append a pair to
    `<report-stem>.ledger.json` beside the report. A `changed` or `removed`
    Markdown sibling is itself a rewritten paragraph: it needs a pair
    covering it, unless it shares its pair's paragraph or sits in the root
    `CHANGELOG.md` or `tests/fixtures/`. A `removed` sibling in a file the
    branch deletes needs only that file's `code_changes` entry, with
    `lines` inside the file as it was at the merge base. Each finding
    needs at least one pair carrying its `sweep` terms; its other pairs
    may leave the field out.
    For each changed file that is not a surviving Markdown file (a deleted
    `.md` file included, and a `.md` path that is now a directory or a
    gitlink), append a `code_changes` entry with the evidence
    (test, harness, mutation) that it is right. Commit as you go; the
    checker reads commits, not the working tree. The gate and the checker
    both read a pair's `lines` at `HEAD`, so bring every pair's range up
    to date before each gate dispatch and each checker run. A gate that
    hashes a stale range judges the wrong paragraph; the pair's `anchor`
    is what lets the checker refuse it (see **Anchors**).
1. **Gate.** Dispatch one agent that did not write the changes, on the
    strongest model available. The dispatch carries, verbatim: the ledger
    path; the diff command (`git diff main...HEAD`); the sweep command
    from contract clause 4 (`check-fix-ledger.sh --sweep -- '<term>' …`),
    so duty 4 searches the way the writer searched; the five gate duties
    below; the paragraph after them on recording each pair's `hash` and
    each code change's `blob`; and the `<report-stem>.gate.json` format
    block under **Files**. A gate given the duties alone writes records
    with no `hash` or `blob`, and the checker rejects them. It writes
    `<report-stem>.gate.json` and nothing else.
1. For every FALSE or OVERREACHES: fix it, update the ledger, commit, and
    re-dispatch the gate on the changed pairs only. A pair's verdict is tied
    to its paragraph's text by hash, and a code change's attack to the blob
    it attacked, so anything fixed after the gate is stale until the gate
    reads it again. Review the fix, not only the thing being fixed. The
    re-gate edits `<report-stem>.gate.json` in place: it replaces only the
    entries for the pairs and code changes it re-read, and keeps every
    other entry. Overwriting the file drops the other verdicts and attacks
    (`missing-verdict`, `missing-attack`); appending a second entry for the
    same pair repeats its id (`schema`).
1. Run `.claude/skills/docs-audit-fix/scripts/check-fix-ledger.sh <ledger> <gate>`
    until it exits 0. Also run the lints and harnesses the diff touches,
    and every `refresh-*.sh` whose output the diff touches. The checker's
    OK run is over the branch's last content commit: the only content
    commit that may follow it is step 7's marker commit. Any other content commit
    made after the OK run, a `refresh-*.sh` regeneration included, means
    running the checker again. A merge from `main` (`gh pr update-branch`) is not a
    content commit: it needs no re-run. When the checker prints the OK
    line, record `git rev-parse HEAD`: the OK line names no commit, and
    step 6 needs it.
1. Push the branch, then open the PR (`gh pr create --head <branch>`).
    The body carries the pair table rendered from the ledger and gate —
    one row per pair: paragraph `file:lines`, artifact `file:lines` or
    command, fix shape, siblings (changed/removed/unchanged counts),
    verdict — plus each code change's attack and result, the findings step
    1 found stale, and the checker's OK line with the commit recorded in
    step 5. When step 7 applies, the body also says
    the marker commit follows that commit.
1. If the report said this audit closes the cycle, run `just docs-audit-done`
    after the checker's OK run, commit the `.github/docs-audit-state` it
    writes as the PR's last commit, the only content commit after that run,
    and push again. Do not re-run the checker over it: the marker is in no
    ledger, so the checker would ask for a `code_changes` entry and a gate
    attack on it. Anyone holding the ledger and gate reproduces the OK
    line with `check-fix-ledger.sh --head <commit> <ledger> <gate>`, using
    the commit recorded in step 5. A content commit needed after the
    marker means reverting the marker commit, re-running the checker, recording the new
    commit as in step 5, updating the PR body's OK line and commit, and
    committing a new marker. If another audit will read these fixes, do
    not run `just docs-audit-done`. A report that does not say which case
    it is counts as another audit will run: no marker commit, and the PR
    body says the report was silent.

## The gate's duties

The gate is a separate agent. It did not write the changes.

1. **Artifact first, paragraph second.** Open the artifact range, form a
    view of what it does, then read the paragraph. For a command artifact,
    run the command yourself and compare what it prints with `observed`.
1. **Verdict per pair:** `TRUE`, `FALSE`, or `OVERREACHES` (true of part of
    the artifact, stated of all of it), with a one-line note for anything
    but TRUE.
1. **Fix shape.** Check the recorded shape against the diff: a fix of any
    shape that introduces a new boundary word (`only`, `every`, `never`, a
    count) not in the artifact is OVERREACHES.
1. **Sibling set, per member.** Re-run the sweep yourself, with each
    pair's `sweep` terms and with any wording of the old claim they leave
    out. A term that misses the distinctive part of the old wording, or an
    alternative wording the finding names, makes the pair FALSE, as does a
    member the ledger omits or marks unchanged for a reason that is false.
1. **Attack every changed matcher, parser or generator.** For each
    `code_changes` entry, construct inputs meant to break it — boundaries,
    empty input, the ordinary case next to the motivating one — and run
    them. Record `attack` (what you ran) and `result` (what happened).
    Confirming the named case works is not an attack.

For each pair record the hash of the paragraph as you read it:
`.claude/skills/docs-audit-fix/scripts/check-fix-ledger.sh --hash <file> <start>-<end>`.
For each code change record the blob you attacked:
`git rev-parse HEAD:<file>`, or `deleted` for a file the branch removes.

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
      "anchor": "egress hosts on the allowlist",
      "artifact": [{"file": "scripts/check-egress-allowlist.sh", "lines": "110-131"}],
      "fix_shape": "scope",
      "sweep": ["every egress host", "all egress hosts"],
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
      "anchor": "**Egress allowlist**",
      "artifact": [{"file": "scripts/check-egress-allowlist.sh", "lines": "110-131"}],
      "fix_shape": "scope",
      "siblings": []
    },
    {
      "id": "p3",
      "finding": 3,
      "file": "docs/architecture/ci.md",
      "lines": "212-212",
      "anchor": "reads the allowlist from",
      "artifact": [{"file": "scripts/check-egress-allowlist.sh", "lines": "110-131"}],
      "fix_shape": "drop",
      "siblings": []
    }
  ],
  "code_changes": [{"file": "scripts/check-egress-allowlist.sh", "evidence": "harness scenario X"}]
}
```

`sweep` holds the old wording, one entry per alternative. It is optional
per pair, but every `finding` needs one pair carrying it; here `p2` and
`p3` share `p1`'s.

An artifact entry for a fact outside the tree is
`{"command": "git config --local --get grep.patternType", "observed": "exit 1, no output"}`
in place of `file` and `lines`.

`lines` is `<start>-<end>` at `HEAD`, inside one paragraph: no blank
line. `anchor` is a phrase inside `lines` that the file holds only once,
such as the first line of the range or the words of a list item or
table row, or else the paragraph's whole text, which may repeat (a
heading's text without its `#` run, say); it ties `lines` to the text
the pair is about. A `removed` sibling's
`lines` is the head-side position its deleted text sat at — for a pure
deletion, the line before it, the line after it, or both. In a file the
branch deletes there is no head side, so it is the lines the text held
at the merge base.
Here `p3` pairs the paragraph that follows the deleted one, where the
deletion sits.

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

It reads the committed diff from the merge base with `main` to `HEAD`
(`--base` and `--head` override each end), refuses to run over uncommitted
tracked changes when the head is `HEAD`, and ignores the caller's diff
configuration (external diff, textconv, header prefixes, `diff.algorithm` and the indent heuristic, `diff.ignoreSubmodules`
and `diff.submodule`, pathspec variables, replace refs). It exits 0 when
every check below passes, 1 with one `check-fix-ledger: <class>: <detail>`
line per finding followed by one count line tallying the findings by class,
and 2 when it cannot run.

- **Shape.** The ledger and the gate each hold exactly one JSON object,
    with no key repeated inside any object (either fault stops the run
    with exit 2);
    every list element is an object; an artifact entry holds either `file`
    and `lines` or a non-blank `command` and `observed`, never both;
    every pair and artifact range is
    `<start>-<end>` with at most six digits a side (a sibling's range is
    checked with the siblings); no ledger file name holds a newline, tab or CR,
    or starts with `./` or `/` (name each from the repository root); pair
    ids and verdict ids are unique, every verdict names a ledger pair,
    and every gate code change carries a `blob` that is an object id or
    `deleted`. Every pair has an `anchor` with no newline, tab, CR or NUL. Text
    made only of white space and invisible format characters, such as a
    zero-width space or a byte-order mark, is blank wherever a field must
    not be: a pair's `anchor`, `command`, `observed`, a sibling's `reason`,
    and a gate's `attack` and `result`. A `schema` finding from
    this shape pass stops the checks below; the later checks also report
    some tracking and range faults as `schema`, and those stop nothing.
- **Completeness.** Every changed Markdown hunk is covered, except in the
    root `CHANGELOG.md` and `tests/fixtures/`, inside a generated
    `<!-- BEGIN <name> -->` / `<!-- END <name> -->` block of the same name
    on both sides, or a pure re-wrap. Other generated Markdown — the
    `# BEGIN just-recipes` block in `README.md`, or a generated file with
    no such markers — is checked like hand-written text.
    Covered means every non-blank paragraph the hunk's new side touches
    overlaps a pair's paragraph, each needing its own pair. A hunk whose
    new side holds no non-blank line (a pure deletion, or text replaced by
    blank lines) is covered by a pair whose paragraph takes in the line
    before or after it. Every other changed
    file, a deleted Markdown file included (one replaced by a directory or
    a gitlink counts as deleted), is listed in `code_changes`. A gitlink
    under a `.md` name also leaves a hunk no pair can cover, since a pair
    needs a file; see the known limits.
- **Artifacts and pairs** name files tracked at `HEAD`, with the range
    inside the file. A command artifact is never run.
- **Anchors.** A pair's `lines` hold no blank line (`schema`), and they
    hold its `anchor`: matched in the pair's file at `HEAD` the way a
    sweep term is (see **Sweep**, with no generated block left out), the
    anchor must match exactly once, and that match must lie inside
    `lines` (`anchor`, naming where it matched). An anchor the file holds
    more than once passes only through the matches that are their
    paragraph's whole text (as the match reads it, a heading's `#` run
    stripped): those must all hash alike, so that any of them carries the
    same verdict, and one must lie inside `lines`. A match inside a
    longer paragraph does not count, and a heading and a plain line with
    its words hash apart, so they are a repeat. A stale range is caught
    this way whether it lands on a blank line, in another paragraph, or
    on another pair's paragraph.
- **Siblings.** An `unchanged` one names a file tracked at `HEAD`, a range
    inside it, and a reason that is not blank. A `changed` one lies inside
    its file and inside one paragraph, clear of its own pair's recorded
    lines, and a covered hunk adds a line inside it whose
    whitespace-collapsed text matches no removed line of that hunk. A
    `removed` one spans at most two lines, may sit one past the end of the
    file, stays clear of its own pair's recorded lines, and is touched by a
    covered hunk that removes a line whose collapsed text matches no added
    line of that hunk. That hunk's reach is the line before and after a pure
    deletion, its new lines plus the next one when it removes more lines
    than it adds, and its new lines otherwise. A `removed` one in a file the
    diff deletes, tracked at the merge base and absent at `HEAD`, needs no
    hunk, only a well-formed range of at most two lines that the file held
    at the merge base. In a file that is not Markdown, or in the root
    `CHANGELOG.md` or `tests/fixtures/`, any hunk touching the range clears
    a `changed` or `removed` sibling, a whitespace-only edit included.
- **Sweep.** Each `sweep` term is searched at the merge base across every
    tracked file except `tests/fixtures/`, any skill's seeded-defect
    fixtures, the root `CHANGELOG.md` and the root `flake.lock`
    (`SWEEP_SCOPE` in the checker), skipping files that hold a NUL byte
    (attributes do not decide it) and hits inside a same-named
    `<!-- BEGIN <name> -->` / `<!-- END <name> -->` block. The match is a
    fixed string, case-sensitive, within one paragraph: each line loses its
    leading white space and a leading run of `#` followed by white space, a
    line left empty ends the paragraph, and white space is collapsed in the
    text and the term, so a term wrapped across lines or comment lines still
    matches. Each hit is mapped to `HEAD`: a line a hunk replaced maps to
    the hunk's new side, a line a pure deletion removed (or one replaced
    only by blank lines) maps to the lines either side, and any other line
    moves with the lines above it; in a file that is not a file at `HEAD`,
    the hit keeps its merge-base lines. The mapped hit must overlap the
    pair's own paragraph or one of its sibling ranges, whatever their status
    (`sweep-uncovered`). A term with no hit is `sweep-empty`, and a
    `finding` value no pair carries a term for is `missing-sweep`, so every
    pair's `finding` must be a whole number of 1 or more. A `sweep` that is
    not a non-empty list of terms, a term that is blank or holds a newline,
    tab, CR or NUL, or a bad `finding` is `schema`. `--sweep [--] <term>…` prints
    the same hits, one `<file>:<start>-<end>: <first line>` per hit, and
    exits 1 when a term matches nothing.
- **Verdicts.** Every pair is gated `TRUE` with a hash equal to its
    paragraph's hash now: the whole blank-line-delimited block, whitespace
    collapsed, so a re-wrap keeps the verdict current, as does a line shift
    once the pair's `lines` follow it (a re-wrap can move the anchor out
    of `lines` too), and any word change makes it stale.
    A `stale-verdict` on a paragraph whose block is unchanged (the same
    text between the same blank lines) means its range moved: update
    `lines`, and the recorded hash holds; an `anchor` finding names where
    the anchor matched. Every code change has a gate entry whose
    `attack` and `result` are not blank and whose `blob` is the one the file
    holds at `HEAD` (or `deleted` when it is absent); a mismatch is
    `stale-attack`.

Finding classes: `schema`, `enum`, `artifact`, `anchor`,
`uncovered-hunk`, `uncovered-file`, `sibling-untracked`, `sibling-reason`,
`sibling-not-changed`, `sibling-not-removed`, `missing-sweep`,
`sweep-empty`, `sweep-uncovered`, `missing-verdict`, `verdict`,
`missing-hash`, `stale-verdict`, `missing-attack`, `stale-attack`. On
success it prints one OK line with the pair, hunk (covered, reflow-only,
generated), code-change and sibling (changed, unchanged, removed) tallies,
a command-artifact tally when the ledger has one, and the sweep-term and
cleared-hit tallies when it has terms; the PR body quotes it.

It does not judge whether a sentence is true or re-sharpened — that is
the gate's job. Its known limits:

- The substance tests compare lines, not words. A line split or join, a
    manual re-wrap, or a moved line can read as a change.
- A `removed` sibling is judged per hunk, so it reaches one line past any
    hunk that deletes more lines than it adds, wherever in the hunk the
    deletion sat. An in-place edit counts: a removed line whose text changed
    is a deletion, so a `removed` sibling on an edited line passes.
- A command artifact's `observed` is not compared with anything; only the
    gate runs the command.
- Prose in script comments and workflow bodies is covered per file through
    `code_changes`, not per paragraph.
- The root `CHANGELOG.md` and `tests/fixtures/` are outside the paragraph
    check: no pair or `code_changes` entry is required for their Markdown
    hunks.
- A `changed` or `removed` sibling outside in-scope Markdown is cleared by
    any touching hunk, as **Siblings** above says, so a whitespace-only edit
    clears it.
- A pure deletion, or a hunk whose new side is only blank lines, sits at
    the lines either side of it. When a whole paragraph goes, those are
    usually its blank line and the next paragraph; a pair's `lines` hold
    no blank line, so the pair goes on the paragraph that follows, or on
    the one before when the last paragraph of a file goes. A hunk whose
    new side is only blank lines is covered by a pair on the paragraph
    directly above or below it, even when the text it removed belonged to
    the other one: replace one
    paragraph's last line and the one blank line after it with a single
    whitespace-only line, pair only the paragraph below, and the run
    passes. With a truly empty line instead, git shows a pure deletion,
    and the same pairing fails.
- A changed file whose name holds a double quote, a backslash or a
    control character stops the run with exit 2, because git quotes such
    a name in every diff the checker reads; rename it. A ledger file name
    holding a backslash is read with it doubled, so it names no file at
    that path: its entry fails as untracked, or as a sibling nothing
    changed or removed.
- A gitlink named like Markdown (`*.md`) cannot pass: its
    `Subproject commit` hunk needs a pair, and a pair's file must be a
    file at `HEAD`. Name the submodule path without `.md`.
- Blank text is white space and invisible format characters (Unicode
    Cf). Other characters that print nothing, such as a Hangul filler or
    a braille blank, count as text.
- The sweep reads the merge base only, so old wording the branch writes
    again is not swept; only the gate, reading the diff, sees it. White
    space inside a term is collapsed, so a term cannot tell one space from
    two, and only ASCII white space collapses: a no-break space must match
    exactly. A phrase split across separate strings (two `echo` lines, a
    concatenation) or across a paragraph break does not match.
- A sibling range is read at `HEAD` like a pair's but carries no anchor,
    so a stale one can clear a hit that has moved away from it. A hit on
    a line a hunk replaced maps to the hunk's whole new side, so a sibling
    anywhere on that side clears it, and one wide range (an `unchanged`
    sibling has no one-paragraph rule) clears every hit it overlaps.
- Only a leading `#` marker is stripped. A blockquote's `>` and a `//`
    comment stay text, so a phrase wrapped across them does not match. In
    Markdown the stripping also takes a heading's `#` run, so a term that
    includes it never matches, and a heading with no blank line after it
    joins the paragraph below.
- A hit in a file the branch turns into a symlink or a directory cannot
    be cleared: its mapped lines fall outside the head file, or it reads as
    deleted while the path still exists, so a `removed` sibling there fails.
- A swept file whose name holds a tab, a newline or a 0x01 or 0x02 byte
    stops the run with exit 2; rename it.
- A finding fixed only outside in-scope Markdown has no pair, so nothing
    carries or checks its terms.
- An anchor proves that `lines` hold the text the writer named, not that
    it is the text the finding meant; the gate reads the paragraph. It is
    matched like a sweep term, so one that includes a heading's `#` run
    matches nothing, and a phrase the file repeats anchors a pair only as
    the whole text of paragraphs that hash alike (see **Anchors**).
- A pure deletion or a blank-only replacement with no non-blank line
    either side of it (between two blank lines in a row, or at the start
    or end of a file) can be covered by no pair. Only a code block or an
    unformatted file holds such a shape.
