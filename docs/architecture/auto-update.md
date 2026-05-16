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
  automerge["gh pr merge --auto --squash"]
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
  push_image["docker push<br/>ghcr.io/rvenutolo/linpeas:<tag>"]
  attest["actions/attest-build-provenance<br/>pin file + bundle + image"]
  release["gh release create <tag><br/>--generate-notes"]
  verify["verify job:<br/>gh attestation verify<br/>each new artifact"]

  trigger --> validate --> build_bundle
  validate --> build_image --> push_image
  build_bundle --> attest
  push_image --> attest
  attest --> release --> verify
```

## Weekly dependency upkeep

```mermaid
flowchart LR
  flakelock["update-flake-lock.yml<br/>Friday 06:00 UTC"]
  renovate["Renovate Friday batch<br/>(action SHAs + Nix pin)"]
  pr1["PR: update flake.lock"]
  pr2["PR: action SHA bumps"]
  ci["required CI checks"]
  merge["squash-merge on green"]

  flakelock --> pr1 --> ci --> merge
  renovate --> pr2 --> ci --> merge
```

## Where this site fits

The Pages workflow runs:

- On every push to `main` (catches docs and code changes).
- On every release (catches release-on-bump pin landings).
- Daily at 10:00 UTC — one hour after the pin-bump cron, so the dashboard reflects the day's bump.
- On manual `workflow_dispatch`.

The Pages site is **not** in the branch-protection required check set; a Pages failure must not block pin bumps. See [CI](ci.md).
