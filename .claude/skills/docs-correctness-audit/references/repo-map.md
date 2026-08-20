# Repo map — ground truth, clusters, generated docs, ephemeral tokens

This file holds the repo-specific facts the audit shares with every reader.
Commands and lists drift; where this file names a generator, recipe, or path,
**trust live output (`just --list`, `ls scripts/`) over this table** if they
disagree, and note the drift as its own finding.

## 1. Ground-truth commands

Run these once and pass the results to every reader so a thing named in a doc is
checked against one authoritative list:

```sh
nix flake show --json          # flake outputs: apps, packages, devShells, checks, overlays, formatter
just --list                    # every recipe (and what each regenerates)
ls scripts/                    # *.sh inventory (check-*, refresh-*, and helpers)
ls .github/workflows/          # workflow filenames
grep -H 'cron:' .github/workflows/*.yml   # authoritative cron schedules
git grep -n '<symbol>'         # existence of options, env vars, secret names, flags
```

The authoritative cron table for prose to match is
`docs/architecture/ci.md` (kept in sync by `check-cron-table.sh`). When a
diagram or runbook names a schedule, verify against both the workflow `cron:`
line and that table.

For CI job / required-check names, the collector emits a **VALID CI JOB / CHECK
NAMES** union allowlist — every workflow job id plus every lint-group member.
Any name a doc calls a "CI job" or "required check" that is absent from that
list is a **ghost** reference (exists nowhere); a name present only as a
lint-group member but described as a standalone job is a **mislabel**. Both are
high severity, and neither is caught by a freshness gate.

## 2. Doc cluster map (one read-only agent per row)

| Cluster        | Files                                                                                                                                                                                     |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| core-docs      | `docs/reference/*.md`, `docs/install/*.md`, `docs/runbooks/*.md`                                                                                                                          |
| security       | `docs/security/*.md`                                                                                                                                                                      |
| arch+dev       | `docs/architecture/*.md`, `docs/development/*.md`                                                                                                                                         |
| root + misc    | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/index.md`, `docs/dashboard.md`, `docs/releases.md`, `docs/invariant-index.md`, `docs/actionlint-embedded-linters.md` |
| claude-tooling | every tracked `.claude/**/*.md` (`git ls-files '.claude/**/*.md'`) except `skills/*/evals/seeded-defects/fixtures/*.md`                                                                   |

Five clusters, not one per `docs/` subdirectory: most of a reader's cost is
fixed per-agent overhead (re-reading the ground-truth bundle, tool setup), so
collapsing the low-drift-density doc groups — `reference`+`install`+`runbooks`
into `core-docs`, `architecture`+`development` into `arch+dev` — cuts reader
count without losing the load-bearing detections. `security` and `root + misc`
stay standalone because they hold the dense, high-severity drift surfaces
(member-vs-job CI prose; required-check counts, ghost jobs, broken links). The
recall-vs-cost evidence for this map is in
[`../evals/tuning-results.md`](../evals/tuning-results.md). Keep `security` and
`root + misc` un-merged; merging them regresses high-severity recall. That
recall-vs-cost tuning covers the four `docs/` clusters; `claude-tooling` is
separate from all of them because it is not user-facing documentation at all —
it is the audit's own specification, so its reader checks this file against the
tree rather than checking the tree against prose.

Part of `.claude/` is tracked and committed — the `docs-correctness-audit` and
`multi-agent-review` skills and their slash commands. Those are maintained
artifacts with real commit history, and they restate facts that live elsewhere
in the tree: the doc cluster map, the generated-doc table below, and the
ephemeral-token regex on this very page. Nothing gates any of those
duplications, so when a generator is added or removed the table here goes
stale silently and the next audit runs against a stale map. The
`claude-tooling` row is what puts them in scope. The fixtures under
`skills/*/evals/seeded-defects/fixtures/` stay out: they exist to carry planted
defects, so reporting them would be reporting the harness working.

`.claude/CLAUDE.md` and the global CLAUDE.md stay read-only reference for the
rules (esp. the ephemeral-token regex); the global one lives outside the repo
and is never edited.

## 3. Generated docs — verify-only, never edit the generated body

These bodies are produced by generators and gated for freshness by CI. Confirm
the current set with `just --list` (the recipes whose descriptions say
"Regenerate …") and `ls scripts/refresh-*.sh`. Do **not** propose prose/drift
edits inside their `BEGIN/END` markers; a fix means fixing the generator.

| Generated target                                                  | Generator (recipe / script)                                      |
| ----------------------------------------------------------------- | ---------------------------------------------------------------- |
| `docs/reference/flake-outputs.md` (flake-show block)              | `just show` / `refresh-flake-show.sh`                            |
| `docs/reference/scripts.md`                                       | `just show-scripts` / `refresh-scripts-reference.sh`             |
| `docs/reference/treefmt-config.md`                                | `just show-treefmt` / `refresh-treefmt-config.sh`                |
| `docs/reference/test-harnesses.md`                                | `refresh-test-harnesses.sh` (no recipe)                          |
| `docs/reference/just-recipes.md` + README recipe block            | `just show-recipes` / `refresh-just-recipes.sh`                  |
| `docs/security/enforcement-matrix.md`                             | `just show-enforcement-matrix` / `refresh-enforcement-matrix.sh` |
| `docs/architecture/ci-dag.md`                                     | `just show-ci-dag` / `refresh-ci-dag.sh`                         |
| pre-commit hook table in `docs/development/git.md`                | `just show-hooks` / `refresh-precommit-table.sh`                 |
| CI summary block in `README.md`                                   | `just show-ci-summary` / `refresh-ci-summary.sh`                 |
| ephemeral-refs-gap block in `docs/development/linting.md`         | `refresh-ephemeral-refs-gap.sh` (no recipe)                      |
| pin-parity block in `docs/architecture/auto-update.md`            | `refresh-pin-parity.sh` (no recipe)                              |
| `docs/_data/dashboard.yml` (drives `dashboard.md`, `releases.md`) | `just site-data` / `gen-dashboard-data.sh`                       |

Hand-written prose *surrounding* a generated block is in scope.

## 4. Ephemeral-token regex (prose-quality dimension)

Tracked docs describe the **current** state; history lives in git. Flag these
banned shapes in tracked docs and comments:

- Planning labels: `GAP-\d+`, `P\d+\.\d+`, `Wave-P?\d+`, `Phase \d+`,
    `AU-P-\d+`, `SC-POST-\d+`, `plan \d+`, `F-\d+`, `finding F-\d+`
- Review-pass labels: `\(D\d+\)`, `\(L\d+[,) ]`, `Per D\d+`, `D\d+:`
- Ad-hoc ticket shapes: `DH-\d+`, `NC-[A-Z]\d+`, any
    `<2-3 uppercase letters>-<digits>` not externally meaningful
- Dates in prose: `\d{4}-\d{2}-\d{2}`, `<Month> \d{4}`, `Q[1-4] \d{4}`.
    Exempt: stable parameter literals (e.g. `X-GitHub-Api-Version: 2022-11-28`),
    static test-fixture data.
- Causal-history phrases: `prior to`, `previously`, `Migration note`,
    `was reshaped`, `Tightened from`, `swapped`, `switched from/to`,
    `legacy <X> was deleted`, `now enforced via X (previously Y)`,
    `added in #?\d+`, `post-PR #\d+`. Rewrite to motivate the current rule by
    current behavior.
- Issue / PR refs: `#\d+`, `PR #\d+`, `issue #\d+`. **Exempt: CHANGELOG and
    release-notes pages**, which structurally list PRs.
- Literal paths into `.claude/` from `README.md`, `docs/**`, and the other
    user-facing trees — nearly all of `.claude/` is untracked, so such a path
    does not resolve for a reader who clones the repo. Tracked `.claude/`
    files may reference their own siblings.

Allowed: incident-warning text that prevents a regression (keep the warning,
drop any dated tag).

The collector emits an **`EPHEMERAL-TOKEN HITS`** section applying these shapes
over all tracked `*.md` files, excluding `.claude/` tooling, `tests/fixtures/`,
`docs/_data/`, and fully exempting `CHANGELOG.md` and `docs/releases.md`
(historical records).

The `.claude/` exclusion is deliberate and does not conflict with the
`claude-tooling` cluster: those files quote the banned shapes as pattern data —
the bullet list above is a list of them — so a shape-matching sweep reports the
specification as a violation. `scripts/check-ephemeral-refs.sh` allowlists the
tree for the same reason. The `claude-tooling` reader covers that prose by
reading meaning instead of matching shapes.

**It reads prose only.** Fenced code blocks, generated `BEGIN`/`END` bodies, and
inline code spans are blanked before matching (line numbering preserved), the
same three regions `scripts/check-ephemeral-refs.sh` exempts. That pass is
load-bearing: without it, every doc that *documents* a banned shape as an
example — `docs/development/linting.md`'s table of banned shapes, the generated
hook table in `docs/development/git.md` — reports as though it carried one.
Deterministic suppressions additionally remove `(fill|stroke|color):#hex`
colors, `&#NNN;` HTML entities, `#N-` anchor targets,
`(SHA|UTF|RFC|ISO|BASE)-NNN` standard acronyms, and the
`X-GitHub-Api-Version: <date>` literal.

**The sweep is not authoritative — `scripts/check-ephemeral-refs.sh` is.** Run
it and believe its exit code; anything the sweep reports that the real lint does
not is a false positive. Two standing caveats: `causal-history` is
advisory-only even in the real lint (it never fails a gate), and the sweep
covers `*.md` only, while the real lint also reads shell, Nix and YAML
comments.

## 5. Invariant-index consistency

`docs/invariant-index.md` is the binding-rules index; `check-orphan-invariants.sh`
enforces that each entry points at a real tracked-doc section and vice versa.
For the consistency dimension, mirror that intent and additionally check the
*semantic* agreement the script cannot: does the index one-liner still match
what the linked section says, and does a claimed invariant have a backing
enforcer (script / CI job / hook) that still exists?

## 6. Internal links / anchors

The collector emits an authoritative **`UNRESOLVED INTERNAL LINKS / ANCHORS`**
section produced by `lychee --offline --include-fragments=anchor-only`, reusing
`lychee.toml`. It runs over all tracked `*.md` files, excluding `.claude/`
tooling and `tests/fixtures/`. External URLs are skipped entirely — only
relative file paths and heading anchors are checked. A listed entry is
authoritative drift: the link target does not exist (high severity). Flag every
entry without re-deriving by eye.
