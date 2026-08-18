# Auto-update architecture

Three independent automations keep the pin current and the release artifacts in sync.

## Daily linpeas pin bump

```mermaid
flowchart TD
  cron["update-linpeas.yml<br/>(daily cron)"]
  api["gh api repos/peass-ng/PEASS-ng/releases/latest"]
  compare{"upstream tag<br/>== current pin?"}
  fetch["curl --location asset_url<br/>cross-check .digest<br/>(hard fail on absent)"]
  validate["validate URL prefix<br/>validate tag regex"]
  hash["nix hash file --sri"]
  write["mktemp + mv<br/>linpeas-pin.json"]
  show["./scripts/refresh-flake-show.sh"]
  pr["gh pr create<br/>chore: bump linpeas to <tag>"]
  automerge["gh pr merge --auto --merge"]
  done(["no-op"])

  cron --> api --> compare
  compare -- yes --> done
  compare -- no --> fetch --> validate --> hash --> write --> show --> pr --> automerge
```

## Release on bump

```mermaid
flowchart TD
  trigger["push to main<br/>changes linpeas-pin.json<br/>(release-on-bump.yml)"]
  preflight["preflight:<br/>classify image-mode<br/>(image presence)"]
  release["release:<br/>validate VERSION shape<br/>gh release create --target $GITHUB_SHA<br/>attest + cosign-sign pin file"]
  image_amd64["image-amd64:<br/>build, push, attest<br/>provenance + SBOM, cosign sign"]
  image_arm64["image-arm64:<br/>build, push, attest<br/>provenance + SBOM, cosign sign"]
  manifest["manifest:<br/>multi-arch manifest by digest"]
  verify["verify:<br/>gh attestation verify<br/>(provenance + SBOM)"]
  changelog["changelog:<br/>git-cliff regenerate + PR"]

  trigger --> release
  trigger --> preflight
  release --> image_amd64
  release --> image_arm64
  preflight --> image_amd64
  preflight --> image_arm64
  image_amd64 --> manifest
  image_arm64 --> manifest
  manifest --> verify
  release --> changelog
```

## Weekly dependency upkeep

```mermaid
flowchart LR
  flakelock["update-flake-lock.yml<br/>compute-lock (read-only)<br/>+ push-and-merge (App token, REST PUT /contents)"]
  renovate["Renovate Friday batch<br/>(action SHAs + Nix pin<br/>+ tracked flake inputs)<br/>minimumReleaseAge: 7 days"]
  pr1["PR: update flake.lock"]
  pr2["PR: action SHA / input bumps"]
  ci["required CI checks"]
  merge["merge-commit on green"]

  flakelock --> pr1 --> ci --> merge
  renovate --> pr2 --> ci --> merge
```

No third-party flake-lock action is used: such actions take the write credential as a `with: token:` input, which would put it inside an externally-controlled action boundary. The split-job design instead confines Nix evaluation to a `contents: read` job; the `push-and-merge` job authenticates to the GitHub API as the `linpeas-flake-bumper` App via a short-lived installation token (`actions/create-github-app-token`), then commits files via REST `PUT /contents`. No `git push`, no PAT in `.git/config`. REST commits authenticated by an App installation token are auto-signed by GitHub's web-flow GPG key, so the bump branch satisfies `required_signatures` on `main`.

## Where this site fits

The Pages workflow runs:

- On every push to `main` (catches docs and code changes).
- On every release (catches release-on-bump pin landings).
- Last slot in the daily window, after `update-linpeas` and `stale-pin-check`, so the dashboard reads a settled state. See [CI — cron schedule](ci.md#cron-schedule).
- On manual `workflow_dispatch`.

The Pages site is **not** in the `protect-main` ruleset's required check set; a Pages failure must not block pin bumps. See [CI](ci.md).

## Pin-diff isolation

Only `scripts/bump-linpeas.sh` may mutate `linpeas-pin.json`. Any
commit landing on `main` that changes the SRI hash, pin URL, or pin
version must isolate that change to `linpeas-pin.json`. The only automatic trigger
for `release-on-bump.yml` is `push.paths: [linpeas-pin.json]` (a manual
`workflow_dispatch` recovery and backfill path also exists); a pin
change that bundles in unrelated files is fine, but a pin change
that arrives via a different script breaks the trigger-contract
assumption.

Enforced by `scripts/check-pin-diff-isolated.sh` via the
`lint-doc-invariants` CI job (member check `pin-diff-isolated`) + pre-commit hook. Lint asserts
exactly one writer (`scripts/bump-linpeas.sh`) under `scripts/`.

## nix/linpeas.nix pin invariants

`pin.version` must match `[0-9]{8}-[0-9a-f]{7,40}`. `pin.url` must start with
`https://github.com/peass-ng/PEASS-ng/releases/download/`. `pin.version` must
also be the release-tag path segment of `pin.url`, so a hand-edited pin
cannot declare one version while fetching a different release's artifact.
Flake-eval-time asserts because `pin.version` interpolates into derivation
names, docker tags, OCI labels.

Upstream peass-ng versioning-scheme change: update regex carefully, keep some
shape check.

## Release VERSION shape validation

`release-on-bump.yml` rejects any tag outside the canonical pin shape
`^[0-9]{8}-[0-9a-f]{7,40}$` (`YYYYMMDD-<hex>`) before calling
`gh release create`.

## Linpeas-pin release-trigger

Any change to `linpeas-pin.json` that lands on `main` MUST cause a
new release to be cut by `release-on-bump.yml`. The next
`verify-latest-release` cron run after the change asserts that the
release-asset copy of `linpeas-pin.json` matches the in-tree copy
(attestation verification). A pin change that lands without firing
the release pipeline leaves `main` in a state where the in-tree pin
diverges from the latest-release-asset pin; the verify cron would
fail on its next weekly run.

Paired with the `pin-diff-isolated` invariant: the only mutator
(`bump-linpeas.sh`) writes only `linpeas-pin.json`, so any pin
change naturally satisfies the `release-on-bump.yml`
`paths: [linpeas-pin.json]` trigger.
