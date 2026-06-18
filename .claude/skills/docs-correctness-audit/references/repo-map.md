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

| Cluster      | Files                                                                                                                                                                                     |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| reference    | `docs/reference/*.md`                                                                                                                                                                     |
| security     | `docs/security/*.md`                                                                                                                                                                      |
| architecture | `docs/architecture/*.md`                                                                                                                                                                  |
| install      | `docs/install/*.md`                                                                                                                                                                       |
| runbooks     | `docs/runbooks/*.md`                                                                                                                                                                      |
| development  | `docs/development/*.md`                                                                                                                                                                   |
| root + misc  | `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`, `docs/index.md`, `docs/dashboard.md`, `docs/releases.md`, `docs/invariant-index.md`, `docs/actionlint-embedded-linters.md` |

`.claude/CLAUDE.md` and the global CLAUDE.md are read-only reference for the
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
| `docs/reference/just-recipes.md` + README recipe block            | `just show-recipes` / `refresh-just-recipes.sh`                  |
| `docs/security/enforcement-matrix.md`                             | `just show-enforcement-matrix` / `refresh-enforcement-matrix.sh` |
| `docs/architecture/ci-dag.md`                                     | `just show-ci-dag` / `refresh-ci-dag.sh`                         |
| pre-commit hook table in `docs/development/git.md`                | `just show-hooks` / `refresh-precommit-table.sh`                 |
| CI summary block in `README.md`                                   | `just show-ci-summary` / `refresh-ci-summary.sh`                 |
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
- Literal paths into `.claude/` from tracked files — the tree is intentionally
    untracked.

Allowed: incident-warning text that prevents a regression (keep the warning,
drop any dated tag).

The collector emits an authoritative **`EPHEMERAL-TOKEN HITS`** section that
applies these shapes over all tracked `*.md` files, excluding `.claude/`
tooling, `tests/fixtures/`, `docs/_data/`, and fully exempting `CHANGELOG.md`
and `docs/releases.md` (historical records). Deterministic suppressions remove
known-good matches: `(fill|stroke|color):#hex` colors, `&#NNN;` HTML entities,
`#N-` anchor targets, `(SHA|UTF|RFC|ISO|BASE)-NNN` standard acronyms, and the
`X-GitHub-Api-Version: <date>` literal. The **structural categories** —
`planning-label`, `review-pass`, `ad-hoc-ticket`, `pr-ref`, and `date` — are
authoritative: flag every hit without re-deriving by eye. The **fuzzy
categories** — `causal-history` (common words like "previously" appear in
legitimate prose) and `claude-path` (a doc may legitimately reference
`.claude/CLAUDE.md`) — are candidates that warrant a quick eyeball before
reporting; do not treat them as automatically confirmed violations.

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
