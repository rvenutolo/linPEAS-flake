# linPEAS-flake

[![CI](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml/badge.svg)](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/ci.yml)
[![Pages](https://github.com/rvenutolo/linPEAS-flake/actions/workflows/pages.yml/badge.svg)](https://rvenutolo.github.io/linPEAS-flake/)
[![Latest release](https://img.shields.io/github/v/release/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/releases)
[![Last commit](https://img.shields.io/github/last-commit/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/commits/main)
[![Open issues](https://img.shields.io/github/issues/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/issues)
[![Open PRs](https://img.shields.io/github/issues-pr/rvenutolo/linPEAS-flake)](https://github.com/rvenutolo/linPEAS-flake/pulls)
[![Renovate dashboard](https://img.shields.io/badge/renovate-dashboard-blue)](https://github.com/rvenutolo/linPEAS-flake/issues?q=is%3Aissue+is%3Aopen+label%3Adependencies+%22Dependency+Dashboard%22)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)
[![License](https://img.shields.io/github/license/rvenutolo/linPEAS-flake)](LICENSE)
[![Nix flake](https://img.shields.io/badge/nix-flake-blue?logo=nixos)](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake)
[![tracks peass-ng](https://img.shields.io/badge/dynamic/json?label=tracks%20peass-ng&query=%24.version&url=https%3A%2F%2Fraw.githubusercontent.com%2Frvenutolo%2FlinPEAS-flake%2Fmain%2Flinpeas-pin.json)](https://github.com/peass-ng/PEASS-ng/releases)

**Docs:** <https://rvenutolo.github.io/linPEAS-flake/>

> **Note:** Yes, this is an absurdly over-engineered way to skip running
> `curl -LO https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh`.
> Also built just for fun. No, I will not be taking questions.

Personal Nix-flake wrapper around [peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng) linpeas.sh.
All credit for LinPEAS itself belongs to the PEASS-ng authors.

## Maintenance

The [Renovate dependency dashboard](https://github.com/rvenutolo/linPEAS-flake/issues?q=is%3Aissue+is%3Aopen+label%3Adependencies+%22Dependency+Dashboard%22) tracks pending dependency bumps, rate-limited PRs, and config errors. Check there if a bump appears stalled.

## Usage

Each install artifact serves a different scenario. Pick the one that
matches your environment.

### With Nix

**`nix run`** — ad-hoc host audit on a Nix-enabled machine. No
install, no state.

```sh
nix run github:rvenutolo/linPEAS-flake -- -a
```

**`nix profile install`** — persistent install on a Nix-enabled
machine. `linpeas` ends up on `$PATH`.

```sh
nix profile install github:rvenutolo/linPEAS-flake
```

### With Docker

**Host audit** — use when Docker is the only install vehicle on the
host. Joins host namespaces and bind-mounts rootfs read-only so
linpeas sees the host instead of the container.

```sh
docker run --rm \
  --pid=host --net=host --ipc=host --userns=host --privileged \
  -v /:/host:ro \
  rvenutolo/linpeas:latest -d /host
```

**Container / sidecar audit** — audit a *different* running
container. Real use cases: CI hardening, base-image review, forensics
on a running workload. Joins the target container's PID and network
namespaces.

```sh
docker run --rm \
  --pid=container:<target> --net=container:<target> \
  rvenutolo/linpeas:latest -a
```

Both registries (`docker.io/rvenutolo/linpeas` and
`ghcr.io/rvenutolo/linpeas`) serve the **same** image bytes — every
release pushes to both with identical content digests and matching
SLSA attestations. See [`docs/install/docker.md`](docs/install/docker.md)
for the full use-case matrix.

### As a flake input

Pull linpeas as a dependency from another flake (e.g. a NixOS config
or dev shell).

```nix
{
  inputs.linpeas-flake = {
    url = "github:rvenutolo/linPEAS-flake";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  # access via inputs.linpeas-flake.packages.${system}.default
}
```

For a full guide (plain flake + flake-parts, pinning, no binary
cache), see [`docs/install/consume-from-flake.md`](docs/install/consume-from-flake.md).

### As an overlay

Expose `pkgs.linpeas` inside your nixpkgs set so existing `pkgs.*`
consumers can reference it.

```nix
{
  nixpkgs.overlays = [ inputs.linpeas-flake.overlays.default ];
  # ...
  # then pkgs.linpeas is available
}
```

See [`docs/install/consume-from-flake.md`](docs/install/consume-from-flake.md)
for pinning guidance that applies to overlay use as well.

## How updates work

Independent automations keep this flake current. Full pipeline,
trigger semantics, and credential split live in
[`docs/architecture/auto-update.md`](docs/architecture/auto-update.md).

<!-- Chronological by cron — daily then weekly. -->

| Workflow                    | When                               | Purpose                                                                                                            |
| --------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `update-linpeas.yml`        | daily + dispatch                   | Bumps `linpeas-pin.json` to the latest upstream tag. Opens PR; auto-merges on green.                               |
| `stale-pin-check.yml`       | daily                              | Files a deduped issue if `update-linpeas` is stalled.                                                              |
| `verify-latest-release.yml` | weekly Fri                         | Re-verifies the latest release's attestations and re-fetches upstream `linpeas.sh` to confirm the pinned SRI hash. |
| `release-on-bump.yml`       | push to `main` changing the pin    | Tags the release, builds + pushes per-arch OCI images (ghcr.io + docker.io), attests SLSA provenance + SBOMs.      |
| `pages.yml`                 | push, PR, release, daily, dispatch | Rebuilds the MkDocs site; deploys via OIDC on non-PR events. Not in the required-check set.                        |
| `update-flake-lock.yml`     | weekly Fri                         | Bumps `nixpkgs` via `nix flake update`; opens auto-merging PR.                                                     |
| Renovate                    | weekly Fri batch                   | Bumps action SHAs + tracked flake inputs after a 7-day cooldown.                                                   |

Bump-workflow commits are authored by the `linpeas-flake-bumper` GitHub
App and web-flow-signed by GitHub, satisfying `required_signatures` on
`main` without a personal access token. See
[`docs/security/repo-config.md`](docs/security/repo-config.md#app-based-bump-auth).

## Versioning

Release tags match the upstream `peass-ng/PEASS-ng` tag verbatim
(shaped `YYYYMMDD-<sha>`). No `v` prefix, no `-flake` suffix.

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

<!-- BEGIN ci-summary -->

- **Build + smoke**: `build-linpeas`, `build-linpeas-arm64`, `flake-check`, `image-smoke`, `image-smoke-arm64`, `smoke-test`, `smoke-test-arm64`.
- **Conventional Commits**: `commitlint`, `lint-pr-title`.
- **Doc quality**: `doc-freshness`, `editorconfig`, `markdownlint`, `typos`.
- **Security/invariant lints**: `changelog-links`, `cliff-tag-pattern`, `dashboard-data-tests`, `dependency-review`, `gitleaks`, `harness-group`, `lint-doc-invariants`, `lint-script-hygiene`, `lint-workflow-security`, `pr-workflows-no-secrets`, `protect-main-drift-check`, `renovate-invariants`, `required-checks-no-paths`, `setup-nix-required`, `tag-protection-drift-check`, `trufflehog`.

<!-- END ci-summary -->

Merge policy: **merge-commit only**, with `required_signatures`
enforced. Every branch commit must independently pass `commitlint` and be
signed; see
[`docs/development/git.md`](docs/development/git.md).

Defense-in-depth supply-chain layers (advisory or implicit, not in the
required-check table; alphabetical):

- `actions.permissions.allowed_actions` = `selected` with a vendor
    allowlist
    ([`docs/security/allowed-actions.md`](docs/security/allowed-actions.md)).
- `image-cve-scan-trivy` and `image-cve-scan-grype` (weekly cron, `image-cve-scan.yml`; Trivy + Grype → code-scanning SARIF,
    advisory only; prevention path is `update-flake-lock`).
- `release-tag-protection` ruleset blocks delete / non-FF / update on
    release tags; drift asserted by `tag-protection-drift-check`.
- `step-security/harden-runner` runs as the first step in every job
    in `egress-policy: block` mode, each with a per-job
    `allowed-endpoints:` allowlist.

### Release attestation verification

Every release runs a `verify` job in `release-on-bump.yml` that runs
`gh attestation verify` against each just-published per-arch digest, reading
from the Sigstore transparency log and the GitHub API, plus `cosign verify`
against the published registries — both registry reads are anonymous, so no
registry credential is required.
A separate weekly cron workflow (`verify-latest-release.yml`) re-verifies the
latest release's image and pin file **and re-fetches the pinned
`linpeas.sh` from upstream to confirm the SRI hash still matches** — this
detects upstream tag-replacement that attestation alone cannot see. Any
failing check surfaces as a red workflow run.

## Verification

Upstream PEASS-ng releases ship no signatures (GPG, cosign, SLSA). Integrity
rests on:

1. SRI hash pinning in `linpeas-pin.json` — Nix refuses to build on mismatch.
1. Flake-eval-time assertions on `pin.version` (YYYYMMDD-<hex>) and `pin.url`
    (peass-ng release prefix) — derivation eval fails on a malformed pin.
1. GitHub Releases API `digest` field cross-check inside the bump workflow
    (hard fail if absent — never a silent skip).
1. Asset-URL prefix validation inside the bump workflow.
1. Weekly upstream parity check (`verify-latest-release.yml`).

This matches the trust model of `curl ... | bash`, but with reproducible,
hash-pinned downloads and SLSA build-provenance attestations. See
[`SECURITY.md`](SECURITY.md) for the full trust model, including the
distinction between build-provenance attestations and content trust.

## Flake outputs

The full `nix flake show --all-systems` tree lives in
[`docs/reference/flake-outputs.md`](docs/reference/flake-outputs.md) and is
auto-regenerated by `scripts/refresh-flake-show.sh`.

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
and tag protection, required-check list — lives in
[`docs/security/repo-config.md`](docs/security/repo-config.md).

## Development

All tooling below — `shfmt`, `shellcheck`, `just`, `pre-commit`,
`nixfmt`, `deadnix`, `statix`, `actionlint`, `zizmor`, `yamllint`,
`prettier`, `lychee`, `check-jsonschema`, and more (see `devShells.default` in
`nix/devshell.nix` for the full set) — is supplied by the flake's `devShells.default`.
You do **not** install any of it manually.

Enter the shell one of two ways:

- `nix develop` — explicit entry.
- `direnv allow` once, then direnv auto-enters on `cd` (`.envrc` runs
    `use flake`).

Either path runs the `shellHook`, which installs the `pre-commit` git hooks
automatically — the `pre-commit install` line below is shown only for
reference / non-flake setups. Prerequisite: Nix
with flakes enabled (`nix-command flakes`).

```sh
# Entry points.
nix develop          # enter dev shell (or direnv allow)
pre-commit install   # one-time, wires git hooks

# just recipes (alphabetical).
# BEGIN just-recipes
just                 # Default: list recipes
just build           # Build the linpeas package
just bump            # Manually refresh linpeas pin from upstream latest release
just check           # Run all flake checks (eval, formatting, pre-commit)
just fmt             # Format every file via treefmt
just image           # Build the OCI image
just lint            # Run pre-commit hooks against all files
just lint-links      # Run lychee link checker against README, SECURITY, and docs/
just show            # Regenerate the <!-- BEGIN/END flake-show --> block in docs/reference/flake-outputs.md
just show-ci-dag     # Regenerate docs/architecture/ci-dag.md from ci.yml needs graph
just show-ci-summary # Regenerate the Continuous integration summary in README.md
just show-enforcement-matrix # Regenerate docs/security/enforcement-matrix.md from invariant-index annotations
just show-hooks      # Regenerate the pre-commit hook table in docs/development/git.md
just show-recipes    # Regenerate the just-recipes list in README.md
just show-scripts    # Regenerate docs/reference/scripts.md from in-script annotations
just show-treefmt    # Regenerate docs/reference/treefmt-config.md from treefmt.nix
just site            # Build the Pages site
just site-data       # Regenerate docs/_data/dashboard.yml standalone
just site-dev        # Live-preview site at http://127.0.0.1:8000 (regenerates data first)
just verify          # Run the batched lint groups, harnesses, and doc-freshness checks CI runs
# END just-recipes
```

## License and attribution

This wrapper is MIT-licensed (see [`LICENSE`](LICENSE)). The wrapped
`linpeas.sh` is MIT-licensed by [peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng/blob/master/LICENSE);
this repo does not redistribute it (Nix fetches it at build time from upstream's
release URL).
