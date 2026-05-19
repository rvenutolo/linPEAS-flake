# linPEAS-flake

[![CI](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml/badge.svg)](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml)
[![Pages](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/pages.yml/badge.svg)](https://rvenutolo.github.io/linPEAS-flake/)
[![Latest release](https://img.shields.io/github/v/release/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/releases)
[![Last commit](https://img.shields.io/github/last-commit/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/commits/main)
[![Open issues](https://img.shields.io/github/issues/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/issues)
[![Open PRs](https://img.shields.io/github/issues-pr/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/pulls)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)
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
# Docker Hub (default registry — no prefix needed)
docker run --rm rvenutolo/linpeas:latest -a

# Or pull explicitly from GitHub Container Registry
docker run --rm ghcr.io/rvenutolo/linpeas:latest -a
```

Both registries serve the **same** image bytes — every release pushes to both
with identical content digests and matching SLSA attestations.

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

Independent automations keep this flake current. Full pipeline,
trigger semantics, and credential split live in
[`docs/architecture/auto-update.md`](docs/architecture/auto-update.md).

<!-- Chronological by cron — daily then weekly. -->

| Workflow                | When                                          | Purpose |
|-------------------------|-----------------------------------------------|---------|
| `update-linpeas.yml`    | daily 09:00 UTC + dispatch                    | Bumps `linpeas-pin.json` to the latest upstream tag. Opens PR; auto-merges on green. |
| `stale-pin-check.yml`   | daily 10:30 UTC                               | Files a deduped issue if `update-linpeas` is stalled. |
| `verify-latest-release.yml` | daily 12:00 UTC                           | Re-verifies the latest release's attestations and re-fetches upstream `linpeas.sh` to confirm the pinned SRI hash. |
| `release-on-bump.yml`   | push to `main` changing the pin               | Tags the release, builds + pushes bundle + per-arch OCI images (ghcr.io + docker.io), attests SLSA provenance + SBOMs. |
| `pages.yml`             | push, PR, release, daily 14:00 UTC, dispatch  | Rebuilds the MkDocs site; deploys via OIDC on non-PR events. Not in the required-check set. |
| `update-flake-lock.yml` | weekly Fri 06:00 UTC                          | Bumps `nixpkgs` via `nix flake update`; opens auto-merging PR. |
| Renovate                | weekly Fri batch                              | Bumps action SHAs + tracked flake inputs after a 7-day cooldown. |

Bump-workflow commits are authored by the `linpeas-flake-bumper` GitHub
App and web-flow-signed by GitHub, satisfying `required_signatures` on
`main` without a personal access token. See
[`docs/security/repo-config.md`](docs/security/repo-config.md#app-based-bump-auth).

## Versioning

Release tags match the upstream `peass-ng/PEASS-ng` tag verbatim
(e.g. `20260510-cd4bd619`). No `v` prefix, no `-flake` suffix.

This keeps the mapping from a release here to the corresponding upstream
release one-to-one and obvious. Wrapper-only fixes (e.g. a `flake.nix` bug
fix unrelated to a pin bump) ride along with the next pin bump rather than
getting their own release tag — acceptable since the wrapper is intentionally
thin.

## Continuous integration

Every PR and push to `main` runs a gated set of required checks before
auto-merge. The authoritative check list lives in
[`docs/security/required-checks.md`](docs/security/required-checks.md);
the full job inventory + cron schedule lives in
[`docs/architecture/ci.md`](docs/architecture/ci.md).

<!-- Alphabetical by category. -->

- **Build + smoke**: `build-linpeas`, `build-linpeas-arm64`,
  `bundle-smoke`, `flake-check`, `image-smoke`, `image-smoke-arm64`,
  `smoke-test`, `smoke-test-arm64`.
- **Conventional Commits**: `commitlint` (per-commit), `lint-pr-title`
  (PR title).
- **Doc quality**: `editorconfig`, `markdownlint`, `typos`.
- **Security/invariant lints**: `dashboard-data-tests`,
  `pr-workflows-no-secrets`, `renovate-invariants`,
  `required-checks-no-paths`, `tag-protection-drift-check`,
  `uses-sha-pinned`.

Merge policy: **merge-commit only**, with `required_signatures`
enforced. Every branch commit must independently pass `commitlint` and be
signed; see
[`docs/development/git.md`](docs/development/git.md).

Defense-in-depth supply-chain layers (advisory or implicit, not in the
required-check table; alphabetical):

- `actions.permissions.allowed_actions` = `selected` with a vendor
  allowlist
  ([`docs/security/allowed-actions.md`](docs/security/allowed-actions.md)).
- `image-cve-scan` (Trivy → code-scanning SARIF, advisory only;
  prevention path is `update-flake-lock`).
- `release-tag-protection` ruleset blocks delete / non-FF / update on
  release tags; drift asserted by `tag-protection-drift-check`.
- `step-security/harden-runner` runs as the first step in every job
  (`egress-policy: audit`).

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
```text
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

## Git workflow

Branches follow `type/description` (kebab-case); commits follow
Conventional Commits and must be signed. PRs land via merge-commit only;
rebase + squash are disabled to preserve branch-commit signatures.

Full runbook — branch naming, commit signing, pre-commit hook list,
local lint commands — lives in
[`docs/development/git.md`](docs/development/git.md).

## Repository configuration

Repository-side posture is locked down: `main` is ruleset-protected with
required checks + signed commits + merge-only; release tags are
ruleset-protected against delete / non-FF / update; only allow-listed
action vendors can run; bump workflows authenticate as a scoped GitHub
App rather than a PAT.

Full breakdown — allowed-actions allowlist, App-based bump auth, branch
+ tag protection, required-check list — lives in
[`docs/security/repo-config.md`](docs/security/repo-config.md).

## Development

```sh
# Entry points.
nix develop          # enter dev shell (or direnv allow)
pre-commit install   # one-time, wires git hooks

# just recipes (alphabetical).
just                 # list recipes
just build           # nix build .#linpeas
just bump            # refresh linpeas pin from upstream
just check           # nix flake check
just fmt             # nix fmt
just lint            # pre-commit run --all-files
just show            # refresh README flake-show block
just site            # nix build .#site
just site-data       # regenerate docs/_data/dashboard.yml
just site-dev        # local preview at http://127.0.0.1:8000
```

## License and attribution

This wrapper is MIT-licensed (see [`LICENSE`](LICENSE)). The wrapped
`linpeas.sh` is MIT-licensed by [peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng/blob/master/LICENSE);
this repo does not redistribute it (Nix fetches it at build time from upstream's
release URL).
