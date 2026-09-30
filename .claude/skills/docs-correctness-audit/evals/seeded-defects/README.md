# Seeded-defect recall harness

Measures how reliably `docs-correctness-audit` (`/docs-audit`) detects
single-instance defects. `plant.sh` seeds one known defect per category into a
disposable clone of the repo and commits the seeds into its history; you run
the audit M times against that copy; `score.sh` reports per-category recall
and run-to-run variance.

## Run trigger

**The audit loop is manual only, and not wired into CI** — a full audit runs
on the order of ten minutes and, across the four user-facing clusters, ~240k reader-tokens per run
summed across readers (see [`../tuning-results.md`](../tuning-results.md) for the measured table;
the `claude-tooling` reader is additional and unmeasured); M runs
multiply that. Run it when you want a recall number (e.g. before/after a skill
edit), not on every change. The harness's own tests do run in CI; see Tests
below.

## Steps

1. Plant the defects:

    ```sh
    ./plant.sh
    ```

    Clones the repo to `${TMPDIR:-/tmp}/docs-audit-seeded-defects`, on a
    `main` branch at HEAD — the tracked skill comes with it, so nothing is
    copied — applies all seeds, and writes `results/manifest-resolved.json`
    plus `results/worktree-path.txt` (the clone's path). It then rewrites the
    clone's whole history to commit the seeds, which takes a few minutes; see
    "A third confound" below for why. The rewrite needs the full history, so
    planting from a shallow clone is refused with exit 2. Leave the checkout alone
    while it runs: planting compares its status before and after, and any
    edit in between fails the plant.

1. Run the audit M times (default M=2, matching the ship gate in
    [`../tuning-results.md`](../tuning-results.md)), fresh session each:

    ```sh
    harness="$PWD"   # this directory; the cp below needs it from inside the clone
    cd "$(cat results/worktree-path.txt)"
    claude            # then run: /docs-audit
    ```

    After each run, copy the emitted report into the harness `results/` dir:

    ```sh
    cp .claude/reports/<the report the audit named>.md \
      "$harness"/results/run-1.md   # run-2.md, run-3.md, ...
    ```

    Name the file rather than globbing for it: the report path carries the
    `-<n>` suffix its ground-truth bundle took, and same-day runs are what
    this loop produces, so a glob over `*-docs-correctness-findings*.md`
    expands to every earlier run's report as well.

1. Score — back in the original checkout's harness directory, not the
    planted clone (the clone has the same tracked `score.sh` but no
    untracked `results/`, so running it there exits 1):

    ```sh
    ./score.sh results/run-*.md
    ```

    Writes `results/recall-<stamp>.md` with per-category recall, a per-seed
    hit/miss matrix across the M runs, and a FLAKY flag for seeds caught in some
    runs but not all.

1. Tear down:

    ```sh
    ./plant.sh --clean
    ```

## Seed format

Each entry in `seeds.json` names a `file`, an `anchor`, an `op`, a `from`
(empty for `insert-after`), and a `payload`. Seeds apply in order, so an anchor must match exactly one line of
its file as the earlier seeds left it. `insert-after` adds the payload as the
line after the anchor; `replace-substr` swaps `from` for the payload inside
the anchor's own text, and planting fails if `from` is not part of the anchor.
An empty payload with `replace-substr` deletes `from`, which is how a
truncation is planted. Every edit field is a string, and anchor, `from` and
payload are each one line; planting refuses a newline in any of them, and a
`replace-substr` anchor that occurs twice on its line. Each seed also needs a
non-empty one-line string `id`, a string `sentinel`, and an integer
`line_tol` from 0 to 1e9; an `also` that is not absent, `null` or `false`
must be an array of edit objects. Planting checks these seed-level rules,
and refuses an empty seed list, before it creates the clone; the
per-edit checks run as each edit is applied, so a refused edit leaves the
clone behind for the next plant to clear.

A seed is scored as hit when a report contains its non-empty `sentinel`, or
cites the seed's `file:line` within `line_tol` of where the edit landed. A
citation must name the whole repo-relative path, optionally with a leading
`./`: a longer path that merely ends in the seed's names another file, and
an absolute path does not match. A cited range such as `file:20-40`
hits when it comes within `line_tol` of the seed's line.

A seed may also carry an `also` list of further `{file, anchor, op, from, payload}` edits, for a defect that lives in two files at once. The manifest
records each one's line, and a citation of any location counts as a hit.

## Determinism

Setup is deterministic — fixed sentinels, fixed seeds, a clone of `HEAD`
whose history is rewritten the same way on every plant.
The **only** stochastic part is the audit itself; that variance (the FLAKY
column) is exactly the signal being measured.

## Expected recall profile

- **Collector-driven** seeds (`broken-link`, `ghost-job`, `wrong-check-count`,
    `ephemeral-token`, `drifted-cron`, `stale-path`) lean on a deterministic
    bundle section — the ephemeral / link / CI-name / required-check-count
    sweeps, the cron table, and the script inventory — expect high, stable
    recall.
- **Reasoning-driven** seeds (`mislabel-member`, `false-exclusive`,
    `near-miss-exclusive`) need a
    comparison the bundle supports but does not perform — the union allowlist
    contains the name and the mislabel is a semantic distinction; the
    `false-exclusive` payload turns on step-level detail the bundle carries
    nowhere, so refuting it means opening the workflow — expect the flaky
    tail. A low number there is a measurement, not a bug in the
    harness. The class is seeded at both ends: `false-exclusive` is flatly
    false (no job lacks the step it names), while `near-miss-exclusive` is true
    of every member of its set but one, and that one exception is listed in the
    same table the claim sits under. The near-miss was expected to be the
    weaker of the two, on the reasoning that a reader who spot-checks two or
    three members finds nothing wrong; measured, both hit 2/2. Two runs is too
    thin to retire the concern, so the expectation stayed open. A later M=2
    run confirmed it: `near-miss-exclusive`
    came back 1/2 FLAKY while `false-exclusive` held 2/2, which is the
    predicted ordering. Treat the near-miss end of the class as the weaker
    one, and expect it to carry the set's flake.
- **Rewrite-shaped** seeds (`distant-contradiction`, `dangling-deixis`) carry
    no bundle support whatsoever and are the hardest of the set. Both encode a
    defect a fix pass leaves behind rather than one that rots on its own:
    `distant-contradiction` plants a claim under `## Tools needed` that the
    page refutes both inside that same section, a dozen lines below the
    insertion point, and again under the cosign section hundreds of lines
    further on, so a reader who reads only the inserted sentence and stops
    will miss it;
    `dangling-deixis` plants "the three checkers listed below" where nothing
    below lists three of anything, which is caught only by resolving the
    pointer instead of reading past it. Both were expected to be the flakiest
    column, on the reasoning that they measure how far a reader searches
    rather than whether a fact is checkable. Measured at M=2, both hit 2/2
    with no flake — so that expectation is refuted, not merely open. Read a
    future low number as a statement about search depth rather than as a
    broken seed, but do not predict one.
- **Generator-class** seeds (`generator-truncation`, `rendering-divergence`,
    `agreed-false-annotation`) sit inside the generated body of
    `docs/reference/scripts.md`, which `SKILL.md` tells readers never to flag
    except as a low-confidence generator-vs-reality gap. They were expected
    to score low because of that instruction. Measured at M=2, they did not:
    both runs compared the rendered lines with their source comments and
    reported `generator-truncation` and `agreed-false-annotation`, and one
    run reported `rendering-divergence`, the set's only flake.
    `generator-truncation` cuts the `refresh-flake-show.sh` `--check` line
    where its source comment wraps, the shape the script-docs parser once
    published; `rendering-divergence` strips the backslashes from the rendered
    octoscan `--ignore` regex, so the page shows a value the script does not
    pass. `agreed-false-annotation` swaps the exit codes in the
    `refresh-treefmt-config.sh` `--check` annotation, in the usage comment
    below it, *and* in its rendered line, so the generator, the page and the
    script's own header agree. What refutes them is the script's exit paths
    and the comment beside the could-not-run exit, plus the pattern the page
    sets: every other generator's `--check` line that names both codes gives
    exit 1 for drift and exit 2 for a check that cannot run.
- **Re-sharpened** seed (`resharpened-claim`) follows the vague "Representative
    hooks" list with a precise sentence naming two scripts as hooks, of which
    only `check-ephemeral-refs` is one; `check-tool-guarded` runs only as the
    `tool-guarded` member of the `lint-script-hygiene` group. It is refuted by
    the hook modules under `nix/hooks/` and by the generated hook table in
    `docs/development/git.md`, which the paragraph links to one sentence
    earlier.

## A confound to keep in view

Six of the fifteen seeds are planted with `insert-after` against a heading
anchor, so they land as a lone sentence directly below a heading (the other
four inserts anchor on body prose, and the `replace-substr` seeds edit an
existing line in place). That shape is
itself a tell: a reader can learn to spot it without doing the verification
the seed exists to measure, and the heading-anchored ones trip markdownlint's
MD022 as a side effect — one
scored run filed the glued-under-heading formatting as a finding in its own
right and named the seeded headings. Recall measured this way is therefore an
upper bound. Varying the insertion point into paragraph interiors would
tighten it, at the cost of re-measuring every seed from scratch.

The generator-class seeds carry a second confound. `generator-truncation`
and `rendering-divergence` edit only the rendered page, so the page no longer
matches what its generator would write, and the `scripts-reference-fresh`
hook would reject them. The real defects passed that gate because the generator
itself was wrong. The audit runs no generator, so the seeds still measure
whether a reader compares the page with its source, but a freshness failure
is a tell the real class never had. `agreed-false-annotation` has no such
tell: it edits the source comment and the page together, and regenerating
the page leaves it unchanged.

A third confound applied to every seed while planting left the seeds as
uncommitted edits: `git status` listed exactly the files that held them. Both
runs of the `bd61a8c5` measurement below noticed, and said so in their
reports, so nothing showed whether a reader found a seed by reading or by
diffing. `plant.sh` now commits the seeds instead, by rewriting the clone's
whole history: each seed enters the first commit whose version of its file
holds its anchor, every audit point in `.github/docs-audit-state` is carried
over to its commit's rewritten sha, and the clone keeps `main` alone, with no
remote, tag, reflog or other branch reaching the unseeded history.

Committing the seeds on top of `HEAD` was measured first and rejected. The
seed commit tops the priority set's log, and the collector's `PROSE HOTSPOTS`
line list, which blames lines to the recent passes, gains the seeded lines of
all three generator-class seeds and of `mislabel-member`. Folding the seeds into the
newest merge instead puts them in the first diff the skill says to read. With
the rewrite, measured at `8854b868`: `git status` and `git diff` are empty,
the log matches the source commit for commit (subjects, identities, dates,
touched paths), and `PROSE HOTSPOTS` and `PASS ATTRIBUTION` print what the
uncommitted plant printed, bar the shas.

What stays visible:

- Blame on a seeded line names the commit that wrote its anchor, whose diff
    then holds the seed. For eleven of the fifteen seeds that commit sits
    outside every window the audit reads, so a reader gets there only from the
    line. For `rendering-divergence` and `agreed-false-annotation` it is a
    commit the ranking's wide window counts anyway, since it rewrote the page,
    and it sits outside the priority set and the line list.
- `wrong-check-count` and `drifted-cron` edit lines that commits after the
    newest audit point wrote, so each seed reads in the priority set's diff as
    that commit's text — where the unseeded line already sat. Only
    re-anchoring them on older lines would move them out.
- `generator-truncation` restores the text its line held before the fix that
    rewrote it, so its blame names the older commit, and the fix's diff no
    longer touches the line.
- Every rewritten commit is unsigned, and a commit sha quoted in tracked text
    (this README's measurement base among them) names nothing in the clone.
    These say the history was rewritten, not where the seeds are.
- `seeds.json` is dropped from every planted commit: it holds every anchor
    and payload, and the first audit over committed seeds found them through
    it, since the controller's own searches and the twin sweep the skill
    requires both read it. So the harness docs name a `seeds.json` the
    planted tree lacks. This README stays, and it still names each seed's
    file and section and quotes several payloads; the `claude-tooling`
    reader audits it as a tracked `.claude/` file, and dropping it would lose
    that coverage and break the links to it. A report that reaches a seed
    through this README, rather than through the doc the seed sits in, marks
    that hit as unearned.

## Last measurement

M=2 at `bd61a8c5`, fifteen seeds: 29/30 (96%). Every seed hit in both runs
except `rendering-divergence`, which hit in one (FLAKY). Read the figure as
an upper bound, for the confounds above.

## Tests

`plant.test.sh` and `score.test.sh` are cheap, deterministic, and need no audit
run. `score.test.sh` validates scoring math against fixtures alone.
`plant.test.sh` validates the planting mechanics *and* asserts every
`seeds.json` anchor, `also` edits included, still resolves exactly once in
its tracked file, and that every recorded line holds the text its seed
planted there. A *committed* reword of a seeded sentence fails `harness-group` until the
seed is re-anchored — `plant.sh` plants from `HEAD`, so an
uncommitted edit still resolves. Those plants skip the history rewrite
(`HISTORY_OVERRIDE=skip`, test-only): this repo's history is too long to
rewrite in a harness, and CI checks it out shallow. The rewrite is tested
on a small repository the harness builds, with two audit points, a merge
and a tag. Together with `../../scripts/collect-ground-truth.test.sh` they
are registered in `scripts/run-harness-group.sh` as `docs-audit-plant`,
`docs-audit-score` and `docs-audit-ground-truth`, and run in the required
`harness-group` CI job. Only the audit loop itself stays manual.
