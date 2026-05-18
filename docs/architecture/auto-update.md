# Auto-update architecture

Three independent automations keep the pin current and the release artifacts in sync.

## Daily linpeas pin bump

```mermaid
flowchart TD
  cron["cron: 09:00 UTC daily<br/>(update-linpeas.yml)"]
  api["gh api repos/peass-ng/PEASS-ng/releases/latest"]
  compare{"upstream tag<br/>== current pin?"}
  fetch["curl --location asset_url<br/>cross-check .digest<br/>(hard fail on absent)"]
  validate["validate URL prefix<br/>validate tag regex"]
  hash["nix hash file --sri"]
  write["mktemp + mv<br/>linpeas-pin.json"]
  show["./scripts/refresh-flake-show.sh"]
  pr["gh pr create<br/>chore: bump linpeas to <tag>"]
  automerge["gh pr merge --auto --rebase"]
  done(["no-op"])

  cron --> api --> compare
  compare -- yes --> done
  compare -- no --> fetch --> validate --> hash --> write --> show --> pr --> automerge
```

## Release on bump

```mermaid
flowchart TD
  trigger["push to main<br/>changes linpeas-pin.json<br/>(release-on-bump.yml)"]
  validate["validate VERSION<br/>shape: [A-Za-z0-9._/-]+"]
  build_bundle["nix build .#linpeas-bundle"]
  build_image["nix build .#linpeas-image"]
  push_image["docker push<br/>ghcr.io + docker.io<br/>per-arch + manifest by digest"]
  attest["actions/attest-build-provenance<br/>pin file + bundle + per-arch image<br/>+ actions/attest-sbom (SPDX)"]
  release["gh release create <tag><br/>--target $GITHUB_SHA<br/>--title <tag><br/>--notes 'Tracks upstream …'"]
  verify["verify job:<br/>gh attestation verify<br/>(provenance + SBOM)"]

  trigger --> validate --> build_bundle
  validate --> build_image --> push_image
  build_bundle --> attest
  push_image --> attest
  attest --> release --> verify
```

## Weekly dependency upkeep

```mermaid
flowchart LR
  flakelock["update-flake-lock.yml<br/>Friday 06:00 UTC<br/>compute-lock (read-only)<br/>+ push-and-merge (BUMP_PAT)"]
  renovate["Renovate Friday batch<br/>(action SHAs + Nix pin<br/>+ tracked flake inputs)<br/>minimumReleaseAge: 7 days"]
  pr1["PR: update flake.lock"]
  pr2["PR: action SHA / input bumps"]
  ci["required CI checks"]
  merge["rebase-merge on green"]

  flakelock --> pr1 --> ci --> merge
  renovate --> pr2 --> ci --> merge
```

The third-party `DeterminateSystems/update-flake-lock` action was removed: it required `BUMP_PAT` as a `with: token:` input, putting the PAT inside an externally-controlled action boundary. The split-job design now confines Nix evaluation to a `contents: read` job and isolates the PAT to a GitHub-owned-action job that pushes via `git -c http.extraheader=...` (never writing to `.git/config`).

## Where this site fits

The Pages workflow runs:

- On every push to `main` (catches docs and code changes).
- On every release (catches release-on-bump pin landings).
- Daily at 14:00 UTC — after the bump-related crons (09:00 `update-linpeas`, 10:30 `stale-pin-check`, 12:00 `verify-latest-release`), so the dashboard reads a settled state. See [CI — cron schedule](ci.md#cron-schedule).
- On manual `workflow_dispatch`.

The Pages site is **not** in the `protect-main` ruleset's required check set; a Pages failure must not block pin bumps. See [CI](ci.md).
