# PR auto-labeling

`.github/workflows/labeler.yml` applies area labels (`ci`, `docs`,
`nix`, `scripts`, `tests`, `security`, `pin`, `renovate`) per
`.github/labeler.yml` globs. `.github/labels.yml` is the catalog of
record — canonical color and description source — for the area,
release-note (`bug`, `enhancement`, `idea`), and `size/*` labels. Some
labels stay out of that manifest deliberately: failure-notification
labels are created on demand by the `notify-workflow-result` composite,
the monthly reminder's `docs-audit` label is created by
`docs-audit-reminder.yml` itself, and Renovate creates its own
`dependencies` PR label. Auto-labeling is not a required check — it is
cosmetic and must not block merge.

There is no label-sync workflow (one would require allowlisting
`crazy-max/*`); see [Label bootstrap](#label-bootstrap) for the manual
`gh label create --force` loop.

`.github/release.yml` groups auto-generated release notes by the area
labels above plus `enhancement`, `bug`, and `idea`, with a `*` catch-all
collecting everything else.

## Size labels

PRs are auto-labeled with `size/XS`, `size/S`, `size/M`, `size/L`, or
`size/XL` by the `size` job in `.github/workflows/labeler.yml` using
`pascalgn/size-label-action`. Thresholds (total changed lines, additions plus deletions):

| Label     | Range   |
| --------- | ------- |
| `size/XS` | 0-9     |
| `size/S`  | 10-29   |
| `size/M`  | 30-99   |
| `size/L`  | 100-499 |
| `size/XL` | 500+    |

### Ignore-list parity

Generator-owned files (changelog, flake-outputs, derived reference docs,
fixture trees) are excluded from the size calculation so that
auto-regenerations do not inflate PR size. The ignore list is supplied
to `pascalgn/size-label-action` via the `IGNORED` env var inline in
the workflow file.

Ownership is declared at the generator, in the header annotation block
`scripts/_script_docs.awk` reads:

| Annotation                | Meaning                                              | On the ignore list |
| ------------------------- | ---------------------------------------------------- | ------------------ |
| `@generates <path>`       | the script owns that file's content                  | required           |
| `@generates-block <path>` | the script splices a block into a hand-authored file | forbidden          |

Most generators own their output file outright. The minority splice a
`<!-- BEGIN x -->` block into a doc that also carries hand-authored
prose: `refresh-precommit-table.sh`, `refresh-pin-parity.sh`,
`refresh-just-recipes.sh`, `refresh-ci-summary.sh`, and
`refresh-ephemeral-refs-gap.sh`. `refresh-just-recipes.sh` is on both
sides — it owns `docs/reference/just-recipes.md` and splices a block into
`README.md`. Which side of the line a doc falls on is therefore a
judgment: several `@generates` pages also splice between markers into a fixed
hand-written header — `docs/architecture/ci-dag.md`,
`docs/reference/flake-outputs.md`, `docs/reference/just-recipes.md`,
`docs/reference/scripts.md`, `docs/reference/treefmt-config.md`. Their
generators refuse to run when the marker is absent, so that header is preserved
rather than emitted; they are annotated `@generates` because the block *is* the
page, while the four files named below are annotated the other way because the
prose is. (`docs/security/enforcement-matrix.md` and
`docs/reference/test-harnesses.md` are the pure cases — their generators write
the whole file, header included.)
Recording it at the generator keeps that judgment reviewable
next to the code that makes it, where a coverage threshold would be a
magic number that moves as the prose around the block grows. Files whose
*substance* is hand-written prose around a block
(`README.md`, `docs/architecture/auto-update.md`,
`docs/development/git.md`, `docs/development/linting.md`) stay off the
list on purpose: ignoring them wholesale would also drop hand-edits to the
surrounding prose from the size count, which is the same failure in the
opposite direction.

**Invariant:** every `@generates` path is on the ignore list, no
`@generates-block` path is, and every remaining entry is one of the
exemptions `scripts/check-size-label-ignores.sh` names — `CHANGELOG.md`
(git-cliff renders it from commit history), `flake.lock` (nix writes
it), and `tests/fixtures/**` (fixture trees are authored as data, not
as reviewable change). Drift in one direction lets a regeneration mask
a legitimately-large change behind a spuriously-small size label; drift
in the other scores a hand-authored file's every edit at zero.

### Label bootstrap

The five `size/*` labels are tracked in `.github/labels.yml`. The
repo does not currently sync that manifest to GitHub automatically;
labels are created manually with the loop below whenever a new
`size/*` label is added to that manifest (the same
`gh label create --force` pattern applies to the area and release-note
labels):

```sh
gh label create size/XS --force --color 009800 --description "0-9 lines changed"
gh label create size/S  --force --color 7cfc00 --description "10-29 lines changed"
gh label create size/M  --force --color fbca04 --description "30-99 lines changed"
gh label create size/L  --force --color ff9800 --description "100-499 lines changed"
gh label create size/XL --force --color d73a4a --description "500+ lines changed"
```
