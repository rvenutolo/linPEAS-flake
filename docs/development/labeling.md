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

**Invariant:** when a new generator-owned file is added to the repo,
its path must be added to the ignore list in the same PR. Drift
allows a regeneration to mask a legitimately-large change behind a
spuriously-small size label.

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
