# Repo map — ground truth, clusters, generated docs, ephemeral tokens

This file holds the repo-specific facts the audit shares with every reader.
Commands and lists drift; where this file names a generator, recipe, or path,
**trust live output (`just --list`, `ls scripts/*.sh scripts/lib/*.sh scripts/*.awk`,
`ls scripts/refresh-*.sh`, the named script's own source) over what is written
here** if they disagree, and note the drift as its own finding.

## 1. Ground-truth commands

Run these once and pass the results to every reader so a thing named in a doc is
checked against one authoritative list.

The cron command spells both workflow globs, `*.yml` and `*.yaml`, to match the
scan sets the repo's own workflow lints use. No `*.yaml` workflow exists today,
so that half goes unmatched and reaches `grep` as a literal path: expect a
`No such file or directory` warning and exit 2. Its stdout is still complete —
the collector drops non-existent paths before scanning, which a hand-run
command does not.

```sh
nix flake show --json          # flake output inventory (the bundle's FLAKE OUTPUTS section is authoritative)
just --list                    # every recipe (and what each regenerates)
ls scripts/*.sh scripts/lib/*.sh scripts/*.awk  # script inventory: entry points, sourced libraries, awk programs
ls .github/workflows/          # workflow filenames
grep -HE '^[[:space:]]*-[[:space:]]*cron:' .github/workflows/*.yml .github/workflows/*.yaml   # authoritative cron schedules (anchored: a prose `cron:` inside a run: block is not a schedule)
grep -c '"context"' .github/rulesets/protect-main.json  # required-check context count
git grep -n '<symbol>'         # existence of options, env vars, secret names, flags
```

The collector filters `nix flake show --json` through a `python3` one-liner
into the one-line `outputs: …` form; when that pipeline fails it falls back to
the raw `nix flake show` tree rendering, so a tree-shaped FLAKE OUTPUTS
section means the filter fell back and should be read as a raw dump; `python3`
is therefore a soft dependency of the collector.

The script inventory names both shell trees and the awk programs because
tracked docs cite the sourced libraries under `scripts/lib/` — `make_temp`
(`scripts/lib/temp.sh`), `enumerate_into` (`scripts/lib/enumerate.sh`) and
their siblings carry invariants of their own — and the `scripts/*.awk`
programs (`_script_docs.awk`, `_attestation_invocations.awk`) by path as
readily as the top-level entry points. A `scripts/*.sh` glob covers neither,
so an inventory that stops at top-level `*.sh` makes every such citation read
as a script that does not exist. The collector emits libraries under a `lib/`
prefix in its **SCRIPTS** section, which is what keeps a library entry
distinguishable from an entry-point one.

The authoritative cron table for prose to match is
`docs/architecture/ci.md` (kept in sync by `check-cron-table.sh`). When a
diagram or runbook names a schedule, verify against both the workflow `cron:`
line and that table.

`.github/rulesets/protect-main.json` is the in-tree mirror of the live
`protect-main` ruleset and the source of truth for required-check **counts** as
well as names — a doc stating how many required checks a PR must pass is
checked against it, and the collector emits that count as its
**REQUIRED-CHECK CONTEXTS** section.

For CI job / required-check names, the collector emits a **VALID CI JOB /
CHECK NAMES** union allowlist — every workflow job id plus every lint-group
member plus every harness-group member (the first field of each `HARNESSES`
entry in `scripts/run-harness-group.sh`). Both workflow globs are enumerated,
`*.yml` and `*.yaml`, matching the scan sets the repo's own workflow lints
use: a suffix the collector does not read contributes no job ids, which turns
every job in that file into a false ghost. Any name a doc calls a "CI job" or
"required check" that is absent from that list is a **ghost** reference
(exists nowhere); a name present only as a lint-group or harness-group member
but described as a standalone job is a **mislabel**. Both are high severity,
and neither is caught by a freshness gate.

## 2. Doc cluster map (one read-only agent per row)

| Cluster        | Files                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| core-docs      | `docs/reference/*.md`, `docs/install/*.md`, `docs/runbooks/*.md`                                                                                                                                                                                                                                                                                                                              |
| security       | `docs/security/*.md`                                                                                                                                                                                                                                                                                                                                                                          |
| arch+dev       | `docs/architecture/*.md`, `docs/development/*.md`                                                                                                                                                                                                                                                                                                                                             |
| root + misc    | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md` (whole-file generated — verify-only, see §3), `docs/index.md`, `docs/dashboard.md`, `docs/releases.md`, `docs/invariant-index.md`, `docs/actionlint-embedded-linters.md`, `tests/README.md`, `.github/PULL_REQUEST_TEMPLATE.md` — **plus any tracked `*.md` outside `.claude/` and `tests/fixtures/` that no other row claims** |
| claude-tooling | every tracked `.claude/` Markdown file (`git ls-files '.claude/*.md'` — git's `*` crosses `/`, where `.claude/**/*.md` would skip files sitting directly in `.claude/`) except `.claude/skills/*/evals/seeded-defects/fixtures/*.md`                                                                                                                                                          |

Five clusters, not one per `docs/` subdirectory: most of a reader's cost is
fixed per-agent overhead (re-reading the ground-truth bundle, tool setup), so
collapsing the low-drift-density doc groups — `reference`+`install`+`runbooks`
into `core-docs`, `architecture`+`development` into `arch+dev` — cuts reader
count without losing the load-bearing detections. `security` and `root + misc`
stay standalone because they hold the dense, high-severity drift surfaces
(member-vs-job CI prose; required-check counts, ghost jobs, broken links). The
recall-vs-cost evidence for this map is in
[`../evals/tuning-results.md`](../evals/tuning-results.md), which also records
a measured three-reader variant that merges `security` into `root + misc`: it
held seed recall at 14/14, so the split is a judgement about depth on
non-seeded drift, not a measured recall win. Keep them un-merged unless
someone re-measures cost head-to-head. That recall-vs-cost tuning covers the
four user-facing clusters; `claude-tooling` is separate from all of them
because it is not user-facing documentation at all — it is the audit's own
specification, so its reader checks this file against the tree rather than
checking the tree against prose.

`root + misc` carries the catch-all clause because the four other rows are
directory globs: a tracked doc outside `.claude/` that falls in none of those
directories — a new top-level `docs/` page as readily as a new root-level one
— matches no row and would otherwise be assigned to no reader while still
appearing in the collector's sweeps. Verify the map covers everything with
`git ls-files '*.md'` minus `tests/fixtures/` and
`.claude/skills/*/evals/seeded-defects/fixtures/` — every result must fall in
some row.

Part of `.claude/` is tracked and committed — the `docs-correctness-audit` and
`multi-agent-review` skills and their slash commands. Those are maintained
artifacts with real commit history, and they restate facts that live elsewhere
in the tree: the generated-doc table below and the ephemeral-token regex on
this very page. Nothing gates either of those duplications, so when a
generator is added or removed the table here goes stale silently and the next
audit runs against a stale map. The `claude-tooling` row is what puts them in
scope. The fixtures under `.claude/skills/*/evals/seeded-defects/fixtures/`
stay out: they are the recall harness's scoring inputs — sample audit reports
`score.sh` grades against a manifest — rather than repo documentation, so
reporting them would be reporting the harness working.

`.claude/CLAUDE.md` and the global CLAUDE.md are untracked and stay read-only
— the global one lives outside the repo entirely. They set the scope of the
rules, not their wording: they are **not** the authority for the
ephemeral-token regex or for how it is enforced. §4 below and
`scripts/lib/ephemeral-refs-scope.sh` are, and because nothing gates an
untracked file, those copies can lag the lint.

## 3. Generated docs — verify-only, never edit the generated body

These bodies are produced by generators and, except where a row says
otherwise, gated for freshness by CI. Confirm
the current set with `just --list` (the recipes whose descriptions say
"Regenerate …") and `ls scripts/refresh-*.sh` — plus the one generator both
routes miss: git-cliff (the CHANGELOG row below). Do **not** propose prose/drift
edits inside their `BEGIN/END` markers; a fix means fixing the generator.

| Generated target                                                                                                                                                                                    | Generator (recipe / script)                                                                                                  |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `docs/reference/flake-outputs.md` (flake-show block)                                                                                                                                                | `just show` / `refresh-flake-show.sh`                                                                                        |
| `docs/reference/scripts.md`                                                                                                                                                                         | `just show-scripts` / `refresh-scripts-reference.sh`                                                                         |
| `docs/reference/treefmt-config.md`                                                                                                                                                                  | `just show-treefmt` / `refresh-treefmt-config.sh`                                                                            |
| `docs/reference/test-harnesses.md`                                                                                                                                                                  | `refresh-test-harnesses.sh` (no recipe; **whole file**)                                                                      |
| `docs/reference/just-recipes.md` + README recipe block (the README half sits inside a fenced block and uses bash-comment `# BEGIN/END just-recipes` markers, not HTML ones)                         | `just show-recipes` / `refresh-just-recipes.sh`                                                                              |
| `docs/security/enforcement-matrix.md` (**whole file**)                                                                                                                                              | `just show-enforcement-matrix` / `refresh-enforcement-matrix.sh`                                                             |
| `docs/architecture/ci-dag.md`                                                                                                                                                                       | `just show-ci-dag` / `refresh-ci-dag.sh`                                                                                     |
| pre-commit hook table in `docs/development/git.md`                                                                                                                                                  | `just show-hooks` / `refresh-precommit-table.sh`                                                                             |
| CI summary block in `README.md`                                                                                                                                                                     | `just show-ci-summary` / `refresh-ci-summary.sh`                                                                             |
| ephemeral-refs-gap block in `docs/development/linting.md`                                                                                                                                           | `refresh-ephemeral-refs-gap.sh` (no recipe)                                                                                  |
| pin-parity block in `docs/architecture/auto-update.md`                                                                                                                                              | `refresh-pin-parity.sh` (no recipe)                                                                                          |
| `docs/_data/dashboard.yml` (untracked/gitignored — regenerated at site build; drives `dashboard.md`, `releases.md`; no freshness gate — `dashboard-data-tests` covers generator failure modes only) | `just site-data` / `gen-dashboard-data.sh`                                                                                   |
| `CHANGELOG.md` (**whole file**)                                                                                                                                                                     | git-cliff in `release-on-bump.yml`'s changelog job; freshness gate `check-changelog-fresh.sh` (no recipe, no `refresh-*.sh`) |

Hand-written prose *surrounding* a generated block is in scope — except
where the row says **whole file**. `docs/reference/test-harnesses.md` carries no
`BEGIN`/`END` markers at all: its generator emits the heading, the
do-not-hand-edit line, the intro paragraph and the regenerate line along with
the census. Nothing in that file is hand-written, so nothing in it is in scope.

`docs/security/enforcement-matrix.md` is whole-file too, markers
notwithstanding: `render_matrix` redirects the entire file, emitting the H1,
the do-not-edit comment and both marker lines around the table. The markers
make it look block-generated, but there is no hand-written prose outside them.
Its rows are driven by the `enforcer:` / `ci:` / `hook:` annotations in
`docs/invariant-index.md`, so a wrong row is a finding against that index
entry, not against this page.

`CHANGELOG.md` is whole-file too, and for the same reason: `cliff.toml`'s
`header` produces the `# Changelog` preamble and its `body` template produces
both the released `## [<tag>]` sections and the `## Unreleased` heading, so no
part of the file is authored prose. Only the released portion is freshness-gated
— `check-changelog-fresh.sh` skips `## Unreleased` because it changes with every
merged commit — but ungated is not hand-written, and a fix there means fixing
`cliff.toml`.

## 4. Ephemeral-token regex (prose-quality dimension)

Tracked docs describe the **current** state; history lives in git. Flag these
banned shapes in tracked docs and comments:

- Planning labels: `GAP-\d+`, `P\d+\.\d+`, `Wave-P?\d+`, `Phase \d+`,
    `AU-P-\d+`, `SC-POST-\d+`, `plan \d+`, `F-\d+`
- Review-pass labels: `\(D\d+\)`, `\(L\d+[,)]`, `Per D\d+`, `D\d+:`
- Ad-hoc ticket shapes (sweep-only — no blocking class; see the caveat
    below): `DH-\d+`, `NC-[A-Z]\d+`, any
    `<2-3 uppercase letters>-<digits>` not externally meaningful
- Dates in prose: `\d{4}-\d{2}-\d{2}`, `<Month> \d{4}`, `Q[1-4] \d{4}`.
    The `X-GitHub-Api-Version: <date>` literal is suppressed by the collector
    sweep only — `RE_DATE` carries no such exemption, and in the real lint the
    literal survives only by sitting inside a code span or fence. Static
    test-fixture data is exempt because `is_allowlisted()` skips
    `tests/fixtures/**` wholesale.
- Causal-history phrases: `previously`, `Migration note`, `Tightened from`,
    `switched from/to`, `legacy <X> was deleted`, `added in #?\d+`,
    `post-PR #?\d+` (a phrase like `now enforced via X (previously Y)` is
    caught by the bare `previously` alternative).
    Rewrite to motivate the current rule by current behavior. Bare verbs and
    prepositions (`prior to`, `swapped`, `was reshaped`) are **not** on this
    list: each reads as repo history or as present-tense prose depending only
    on its subject, so matching them fires on threat models and hypothetical
    drift as readily as on rot.
- Issue / PR refs: `#\d+`, `PR #\d+`, `issue #\d+`.
- Literal paths into `.claude/` from any scanned source outside the file
    allowlist — Markdown prose and shell, Nix and YAML comments alike, since
    `RE_CLAUDE` is unscoped. The allowlist is `CHANGELOG.md`,
    `docs/releases.md`, `tests/fixtures/**` and `.claude/**`. Nearly all of
    `.claude/` is untracked, so such a path does not resolve for a reader who
    clones the repo; tracked `.claude/` files may reference their own siblings
    because the allowlist skips that tree outright.

`CHANGELOG.md` and `docs/releases.md` are exempt from **every** class above,
not merely the PR-ref one: `is_allowlisted()` skips both files before any
class runs, because they structurally record PRs and dates.

Allowed: incident-warning text that prevents a regression (keep the warning,
drop any dated tag).

The collector emits an **`EPHEMERAL-TOKEN HITS`** section applying these shapes
over all tracked `*.md` files, excluding `.claude/` tooling, `tests/fixtures/`,
`docs/_data/`, and fully exempting `CHANGELOG.md` and `docs/releases.md`
(historical records).

The `.claude/` exclusion is deliberate and does not conflict with the
`claude-tooling` cluster: those files quote the banned shapes as pattern data
— the bullet list above is a list of them — so a shape-matching sweep reports
the specification as a violation. `is_allowlisted()` in
`scripts/lib/ephemeral-refs-scope.sh` skips the tree for the same reason. The
`claude-tooling` reader covers that prose by reading meaning instead of
matching shapes.

**It reads prose only.** Fenced code blocks (backtick or tilde), inline code
spans, and generated `BEGIN`/`END` bodies are blanked before matching (line
numbering preserved) — the same three regions
`scripts/check-ephemeral-refs.sh` exempts, in the same order: fences are
recognized first, and inline code spans are blanked before a `BEGIN` is looked
for, so a marker quoted in a span or a fence is documentation, not a block
opener. Like the lint, the sweep fails loud on an unterminated fence or
generated block rather than silently blanking to end-of-file — and in the
collector that failure aborts the whole run mid-bundle: the sections after
**`EPHEMERAL-TOKEN HITS`** (the links check included) never emit. A short
bundle therefore means a malformed doc — record the offender as a
high-severity finding and treat the never-emitted sections as unchecked rather
than clean. That pass is load-bearing: without it, every doc that *documents*
a banned shape as an example — `docs/development/linting.md`'s table of banned
shapes, the generated hook table in `docs/development/git.md` — reports as
though it carried one. Three classes additionally carry a deterministic
suppression: `pr-ref` drops hit lines carrying `(fill|stroke|color):#hex`
colors, `&#NNN;` HTML entities, or `#N-` anchor targets; `ad-hoc-ticket` drops
`(SHA|UTF|RFC|ISO|BASE)-NNN` standard acronyms; `date` drops the
`X-GitHub-Api-Version: <date>` literal. Each acts on the whole line of its own
class, not the token, so a line that carries both a suppressed shape and a
genuine banned token is dropped — a harmless false negative, since the sweep
is advisory and the real lint is the authority.

**The sweep is not authoritative — `scripts/check-ephemeral-refs.sh` is.** Run
it and believe its exit code; anything the sweep reports that the real lint does
not is a false positive. The lint's complete class set is in
`scripts/lib/ephemeral-refs-scope.sh`: `RE_ISSUE`, `RE_DATE`, `RE_PLANNING`,
`RE_REVIEW` and `RE_CLAUDE` block, `RE_CAUSAL` warns. The sweep transcribes
the blocking classes from those constants, left boundary guards included, so a
banned shape sitting inside a larger token (`UTF-8`, `PDF-1.7`, `ID5:`,
`abc#12`) is no more a sweep hit than a gate failure. The advisory
`causal-history` class is matched case-insensitively on both sides, matching
`RE_CAUSAL`'s `--ignore-case` pass in the lint, so a sentence-initial
`Previously` is a hit in the sweep exactly as it is in the lint; the blocking
classes stay case-sensitive on both sides. Three standing caveats where this
page, the collector sweep, and the real lint still diverge:

- `causal-history` is advisory-only even in the real lint — it never fails a
    gate, so a hit there is a style nit.
- The sweep covers `*.md` only, while the real lint also reads shell, Nix and
    YAML comments.
- **`ad-hoc-ticket` is sweep-only.** No blocking class implements it —
    `RE_PLANNING` enumerates `GAP-`, `P<n>.<n>`, `Wave-P?<n>`, `Phase <n>`,
    `AU-P-`, `SC-POST-`, `plan <n>` and `F-<n>`, and stops there. A generic
    `[A-Z]{2,3}-[0-9]+` matcher would fire on `UTF-8`, `SHA-256`, `RFC-822` and
    `ISO-8601`; the enumerated shapes carry explicit boundary guards precisely
    because that shape is noisy. `ad-hoc-ticket` is the one class the sweep
    runs without such a guard, which is why it leans on the
    `(SHA|UTF|RFC|ISO|BASE)-NNN` suppression instead. Every `ad-hoc-ticket`
    hit is therefore a judgement call for the reader, never a gate failure.

## 5. Invariant-index consistency

`docs/invariant-index.md` is the binding-rules index;
`check-orphan-invariants.sh` enforces that each index pointer resolves to an
existing file under `docs/`, and that every non-`EXEMPT` docs file has an
entry. The script's `EXEMPT` array is the authority on what is exempt; per the
index preamble's own taxonomy it holds generator-owned pages, the live-status
template pages (`dashboard.md`, `releases.md`) whose content is a rendering
rather than a rule, overview pages that route to rules held elsewhere, the
index itself, and two install guides (`install/consume-from-flake.md`, which
carries no index entry at all, and `install/nix.md`, whose exemption is inert
because it does carry one) — not every generated page (a generated page can
still carry an index entry). Heading anchors are a separate lint,
`check-doc-anchors.sh`. For the consistency dimension, mirror that intent and
additionally check the *semantic* agreement the script cannot: does the index
one-liner still match what the linked section says, and does a claimed
invariant have a backing enforcer (script / CI job / hook) that still exists?

## 6. Internal links / anchors

The collector emits an authoritative **`UNRESOLVED INTERNAL LINKS / ANCHORS`**
section produced by `lychee --offline --include-fragments=anchor-only`,
reusing `lychee.toml`. It runs over all tracked `*.md` files — the tracked
`.claude/` tooling included, since its links are ordinary links even though
its prose quotes banned token shapes — excluding only `tests/fixtures/`,
`docs/_data/` and the seeded-defect fixtures under
`.claude/skills/*/evals/seeded-defects/fixtures/`, which are the recall
harness's scoring inputs rather than repo documentation. That list is only the
first of two filters: the run passes `--config lychee.toml`, whose
`exclude_path` entries are **regular expressions matched against each input
path as it was passed** (absolute, here), so any entry matching a tracked doc
removes it from the sweep — lychee warns once per refused input, which the
collector counts and surfaces as the `(lychee skipped …)` marker described
below. The two agree today — verify with
`lychee --dump-inputs` if a coverage claim depends on it. External URLs are
skipped entirely — only relative file paths and heading anchors are checked. A
listed entry is authoritative drift: the link target does not exist (high
severity). Flag every entry without re-deriving by eye. Three non-result
markers mean the sweep did not cover what it claims to, and none is a clean
read — the skip marker reports independently, so it can head a real error
list rather than replacing one: `(lychee not found — internal-link sweep skipped)` when `lychee` is off
the collector's `PATH`;
`(lychee failed — internal-link sweep unusable; exit N)`
when lychee ran but could not complete — a tracked doc deleted from the
worktree but still in the index produces this one; and
`(lychee skipped N of M input(s) — internal-link sweep incomplete)`
when lychee refused individual inputs, which is what an `exclude_path`
entry matching a tracked doc looks like. Record links as unchecked in the coverage note whenever any of
them appears. Only `(none)` means every input was read and every link
resolved.
