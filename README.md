# linPEAS-flake

[![CI](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml/badge.svg)](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml)
[![Pages](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/pages.yml/badge.svg)](https://rvenutolo.github.io/linPEAS-flake/)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/rvenutolo/linPEAS-flake/badge)](https://scorecard.dev/viewer/?uri=github.com/rvenutolo/linPEAS-flake)
[![Latest release](https://img.shields.io/github/v/release/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/releases)
[![Last commit](https://img.shields.io/github/last-commit/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/commits/main)
[![License](https://img.shields.io/github/license/rvenutolo/linPEAS-flake)](LICENSE)
[![Nix flake](https://img.shields.io/badge/nix-flake-blue?logo=nixos)](https://nixos.wiki/wiki/Flakes)
[![tracks peass-ng](https://img.shields.io/badge/dynamic/json?label=tracks%20peass-ng&query=%24.version&url=https%3A%2F%2Fraw.githubusercontent.com%2Frvenutolo%2FlinPEAS-flake%2Fmain%2Flinpeas-pin.json)](https://github.com/peass-ng/PEASS-ng/releases)

**Docs:** <https://rvenutolo.github.io/linPEAS-flake/>

> **Note:** Yes, this is an absurdly over-engineered way to skip running
> `curl -LO https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh`.
> Also built just for fun. No, I will not be taking questions.

Personal Nix-flake wrapper around [peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng) linpeas.sh.
All credit for LinPEAS itself belongs to the PEASS-ng authors.

## Usage

### With Nix
```sh
nix run github:rvenutolo/linPEAS-flake -- -a
```

Persistent install:
```sh
nix profile install github:rvenutolo/linPEAS-flake
```

### With Docker
The image audits the **container** it runs in (container hardening, CI base-image
scanning, forensics on a mounted captured filesystem). For a host audit, prefer
the Nix or bundle install — or run with host namespaces explicitly. See
[`docs/install/docker.md`](docs/install/docker.md) for use-case framing and the
host-audit invocation.
```sh
docker run --rm ghcr.io/rvenutolo/linpeas:latest -a
```

### Without Nix or Docker (portable bundle)
The bundle is just `linpeas.sh` with `#!/usr/bin/env bash` — same script, single
arch-agnostic asset.
```sh
curl -L https://github.com/rvenutolo/linPEAS-flake/releases/latest/download/linpeas-bundle.sh -o linpeas
chmod +x linpeas
./linpeas -a
```

### As a flake input
```nix
{
  inputs.linpeas-flake.url = "github:rvenutolo/linPEAS-flake";
  # ...
  # access via inputs.linpeas-flake.packages.${system}.linpeas
}
```

### As an overlay
```nix
{
  nixpkgs.overlays = [ inputs.linpeas-flake.overlays.default ];
  # ...
  # then pkgs.linpeas is available
}
```

## How updates work

Three independent automations keep this flake current:

### Daily linpeas pin bump (`update-linpeas.yml`)
- Cron 09:00 UTC + manual dispatch.
- Queries `peass-ng/PEASS-ng` releases API. If the latest tag differs from the
  pinned `linpeas-pin.json`, downloads the new `linpeas.sh`, **validates the
  asset URL stays within the expected `github.com/peass-ng/PEASS-ng/releases/
  download/` prefix**, **hard-fails if the GitHub-API `digest` field is
  missing or non-`sha256:`** (previously a silent skip), cross-checks the
  digest, computes the SRI hash, and atomically rewrites the pin.
- Regenerates the README flake-outputs block in the same commit.
- Opens a PR (`chore: bump linpeas to <tag>`) authored by `github-actions[bot]`
  via a fine-grained PAT (so CI fires; the default `GITHUB_TOKEN` would not
  trigger `pull_request` workflows).
- CI gates auto-merge. On green, GitHub squash-merges to `main`.

### Release on bump (`release-on-bump.yml`)
- Triggers when `linpeas-pin.json` changes on `main`.
- Tags the release with the upstream tag verbatim (e.g. `20260510-cd4bd619`)
  — see Versioning below.
- Builds and attaches:
  - `linpeas-bundle.sh` — raw `linpeas.sh` with `#!/usr/bin/env bash`, a
    single arch-agnostic asset.
  - OCI image to `ghcr.io/rvenutolo/linpeas:<tag>` and `:latest`.
- Generates SLSA build provenance attestations for the pin file, the bundle,
  and the image. Verify with
  `gh attestation verify <artifact> --repo rvenutolo/linPEAS-flake`.

### Weekly dependency upkeep
- `update-flake-lock.yml` — Friday 06:00 UTC. Bumps the `nixpkgs` input via
  `DeterminateSystems/update-flake-lock`. CI-gated auto-merge.
- Renovate (Friday batch) — bumps GitHub Action SHAs and the pinned Nix
  version in CI workflows (custom regex manager). CI-gated auto-merge.

### Pages site (`pages.yml`)
- Triggers: push to `main`, PR, release published, daily 10:00 UTC cron,
  and manual dispatch.
- On every trigger: `scripts/gen-dashboard-data.sh` regenerates
  `docs/_data/dashboard.yml` from `linpeas-pin.json` + GitHub API. `nix
  build .#site` then renders the MkDocs Material site. On non-PR events
  the artifact is deployed to <https://rvenutolo.github.io/linPEAS-flake/>
  via `actions/deploy-pages` over OIDC.
- Pages is **not** in the branch-protection required check set — a
  Pages failure must not block linpeas-bump PRs from auto-merging. A
  failure auto-files a deduped issue tagged `pages-build-failure`.

## Versioning

Release tags match the upstream `peass-ng/PEASS-ng` tag verbatim
(e.g. `20260510-cd4bd619`). No `v` prefix, no `-flake` suffix.

This keeps the mapping from a release here to the corresponding upstream
release one-to-one and obvious. Wrapper-only fixes (e.g. a `flake.nix` bug
fix unrelated to a pin bump) ride along with the next pin bump rather than
getting their own release tag — acceptable since the wrapper is intentionally
thin.

## Continuous integration

Every PR and push to `main` runs seven required jobs that gate auto-merge:

| Job                   | Runner             | What it tests |
|-----------------------|--------------------|---------------|
| `flake-check`         | `ubuntu-latest`    | `nix flake check` — eval, treefmt, deadnix, statix, actionlint, yamllint, shellcheck, README-staleness, schema |
| `build-linpeas`       | `ubuntu-latest`    | `nix build .#linpeas` — fetches upstream `linpeas.sh`, verifies SRI hash, builds the derivation |
| `smoke-test`          | `ubuntu-latest`    | `./result/bin/linpeas -h` exits 0 |
| `build-linpeas-arm64` | `ubuntu-24.04-arm` | aarch64 build of `linpeas` |
| `smoke-test-arm64`    | `ubuntu-24.04-arm` | aarch64 `-h` smoke |
| `image-smoke`         | `ubuntu-latest`    | builds OCI image, `docker load`, `docker run --rm <img> -h` exits 0 |
| `bundle-smoke`        | `ubuntu-latest`    | builds bundle, `./result/linpeas-bundle.sh -h` exits 0 |

A non-blocking coverage matrix runs `flake-check` and `build-linpeas` across
`ubuntu-latest` / `macos-latest` × stable Nix / unstable Nix. Failures there
surface in the PR view but do not gate merges.

Cache: `DeterminateSystems/flakehub-cache-action` (free for public repos).
All third-party actions are SHA-pinned with `# vX` version comments;
Renovate maintains them.

### Release attestation verification

Every release runs a `verify` job in `release-on-bump.yml` that downloads the
just-published bundle + image and runs `gh attestation verify` on each.
A separate daily cron workflow (`verify-latest-release.yml`) re-verifies the
latest release's bundle, image, and pin file **and re-fetches the pinned
`linpeas.sh` from upstream to confirm the SRI hash still matches** — this
detects upstream tag-replacement that attestation alone cannot see. Any
failing check surfaces as a red workflow run.

## Verification

Upstream PEASS-ng releases ship no signatures (GPG, cosign, SLSA). Integrity
rests on:

1. SRI hash pinning in `linpeas-pin.json` — Nix refuses to build on mismatch.
2. Flake-eval-time assertions on `pin.version` (YYYYMMDD-<hex>) and `pin.url`
   (peass-ng release prefix) — derivation eval fails on a malformed pin.
3. GitHub Releases API `digest` field cross-check inside the bump workflow
   (hard fail if absent — never a silent skip).
4. Asset-URL prefix validation inside the bump workflow.
5. Daily upstream parity check (`verify-latest-release.yml`).

This matches the trust model of `curl ... | bash`, but with reproducible,
hash-pinned downloads and SLSA build-provenance attestations. See
[`SECURITY.md`](SECURITY.md) for the full trust model, including the
distinction between build-provenance attestations and content trust.

## Flake outputs

<!-- BEGIN flake-show -->
```
├───apps
│   ├───aarch64-darwin
│   │   ├───default: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│   │   └───linpeas: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│   ├───aarch64-linux
│   │   ├───default: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│   │   └───linpeas: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│   ├───x86_64-darwin
│   │   ├───default: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│   │   └───linpeas: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│   └───x86_64-linux
│       ├───default: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
│       └───linpeas: app: Linux Privilege Escalation Awesome Script (LinPEAS) from peass-ng
├───checks
│   ├───aarch64-darwin
│   │   ├───formatting: derivation 'treefmt-check'
│   │   └───pre-commit: derivation 'pre-commit-run'
│   ├───aarch64-linux
│   │   ├───formatting: derivation 'treefmt-check'
│   │   └───pre-commit: derivation 'pre-commit-run'
│   ├───x86_64-darwin
│   │   ├───formatting: derivation 'treefmt-check'
│   │   └───pre-commit: derivation 'pre-commit-run'
│   └───x86_64-linux
│       ├───formatting: derivation 'treefmt-check'
│       └───pre-commit: derivation 'pre-commit-run'
├───devShells
│   ├───aarch64-darwin
│   │   └───default: development environment 'nix-shell'
│   ├───aarch64-linux
│   │   └───default: development environment 'nix-shell'
│   ├───x86_64-darwin
│   │   └───default: development environment 'nix-shell'
│   └───x86_64-linux
│       └───default: development environment 'nix-shell'
├───formatter
│   ├───aarch64-darwin: package 'treefmt'
│   ├───aarch64-linux: package 'treefmt'
│   ├───x86_64-darwin: package 'treefmt'
│   └───x86_64-linux: package 'treefmt'
├───overlays
│   └───default: Nixpkgs overlay
└───packages
    ├───aarch64-darwin
    │   ├───default: package 'linpeas-20260510-cd4bd619'
    │   └───linpeas: package 'linpeas-20260510-cd4bd619'
    ├───aarch64-linux
    │   ├───default: package 'linpeas-20260510-cd4bd619'
    │   ├───linpeas: package 'linpeas-20260510-cd4bd619'
    │   ├───linpeas-bundle: package 'linpeas-bundle-20260510-cd4bd619'
    │   ├───linpeas-image: package 'linpeas.tar.gz'
    │   └───site: package 'linpeas-flake-site-20260510-cd4bd619'
    ├───x86_64-darwin
    │   ├───default: package 'linpeas-20260510-cd4bd619'
    │   └───linpeas: package 'linpeas-20260510-cd4bd619'
    └───x86_64-linux
        ├───default: package 'linpeas-20260510-cd4bd619'
        ├───linpeas: package 'linpeas-20260510-cd4bd619'
        ├───linpeas-bundle: package 'linpeas-bundle-20260510-cd4bd619'
        ├───linpeas-image: package 'linpeas.tar.gz'
        └───site: package 'linpeas-flake-site-20260510-cd4bd619'
```
<!-- END flake-show -->

## Development

```sh
nix develop          # enter dev shell (or direnv allow)
just                 # list recipes
just build           # nix build .#linpeas
just check           # nix flake check
just fmt             # nix fmt
just lint            # pre-commit run --all-files
just bump            # refresh linpeas pin from upstream
just show            # refresh README flake-show block
just site            # nix build .#site
just site-data       # regenerate docs/_data/dashboard.yml
just site-dev        # local preview at http://127.0.0.1:8000
pre-commit install   # one-time, wires git hooks
```

## License and attribution

This wrapper is MIT-licensed (see [`LICENSE`](LICENSE)). The wrapped
`linpeas.sh` is MIT-licensed by [peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng/blob/master/LICENSE);
this repo does not redistribute it (Nix fetches it at build time from upstream's
release URL).
