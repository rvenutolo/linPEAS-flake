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
