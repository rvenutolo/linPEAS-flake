# PR auto-labeling

`labeler.yml` applies area labels (`ci`, `docs`, `nix`, `scripts`,
`tests`, `security`, `pin`, `renovate`) per `.github/labeler.yml`
globs. Label catalog of record: `.github/labels.yml`. Not a required
check — auto-labeling is cosmetic and must not block merge.

`.github/labels.yml` is the canonical label-color/description source.
Sync to repo manually with one-shot `gh label create --force` loop —
no sync workflow (would require allowlisting `crazy-max/*`).

`.github/release.yml` groups auto-generated release notes by these
labels.

## Size labels

PRs are auto-labeled with `size/XS`, `size/S`, `size/M`, `size/L`, or
`size/XL` by the `size` job in `.github/workflows/labeler.yml` using
`pascalgn/size-label-action`. Thresholds (additive line changes):

| Label     | Range   |
| --------- | ------- |
| `size/XS` | 0-9     |
| `size/S`  | 10-29   |
| `size/M`  | 30-99   |
| `size/L`  | 100-499 |
| `size/XL` | 500+    |

### Ignore-list parity

Generator-owned files (changelog, flake-outputs, derived doc blocks,
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

Most generators splice a `<!-- BEGIN x -->` block into a doc that also
carries hand-authored prose; a few (`scripts/refresh-test-harnesses.sh`,
`scripts/gen-dashboard-data.sh`) own their output file outright. Which
side of the line a doc falls on is therefore a judgment. Recording it at the generator
keeps that judgment reviewable next to the code that makes it, where a
coverage threshold would be a magic number that moves as the prose
around the block grows. Files carrying a block inside hand-written
prose (`docs/development/git.md`, `README.md`) stay off the list on
purpose: ignoring them wholesale would also drop hand-edits to the
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
new labels are created once manually after the labels-manifest PR
merges:

```sh
gh label create size/XS --color 009800 --description "0-9 lines changed"
gh label create size/S  --color 7cfc00 --description "10-29 lines changed"
gh label create size/M  --color fbca04 --description "30-99 lines changed"
gh label create size/L  --color ff9800 --description "100-499 lines changed"
gh label create size/XL --color d73a4a --description "500+ lines changed"
```
