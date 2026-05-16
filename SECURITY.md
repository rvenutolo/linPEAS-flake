# Security Policy

## Reporting issues in this flake wrapper

If you find a security issue in the **flake wrapper itself** (the Nix code,
GitHub Actions workflows, helper scripts, or release-publishing automation in
this repo), please email <venutolo@hotmail.com>. Do not open a public issue.

## Reporting issues in LinPEAS itself

This repo is a thin Nix-flake wrapper around upstream
[peass-ng/PEASS-ng](https://github.com/peass-ng/PEASS-ng). It does not
modify `linpeas.sh`. Vulnerabilities in LinPEAS itself should be reported
upstream via the PEASS-ng project's reporting channels.

## Verification

The pinned `linpeas.sh` is recorded in `linpeas-pin.json` with an SRI
hash. `nix build` will refuse to build if the downloaded blob does not
match. The auto-update workflow additionally cross-checks the GitHub
Releases API `digest` field on each bump (hard fail if absent — never a
silent skip). Upstream PEASS-ng releases ship no signatures (GPG, cosign,
SLSA, etc.), so all integrity rests on the pinned hash plus trust in
GitHub's hosting.

The daily `verify-latest-release` cron additionally re-fetches the pinned
`linpeas.sh` URL and compares the SRI hash against the pin file, detecting
upstream tag replacement (intentional or compromise).

## Trust model and SLSA attestation semantics

Every release artifact (bundle, OCI image, pin file) carries a SLSA
build-provenance attestation, verifiable with
`gh attestation verify <artifact> --repo rvenutolo/linPEAS-flake`. These
attestations prove **build provenance**: the published artifact was
produced by this repository's release workflow at the recorded commit
SHA. They do **not** prove **content trust**: this wrapper repo does not
review, audit, or otherwise vet upstream `linpeas.sh` content before
publishing it.

If you require content review, do not consume releases automatically.
Read the upstream release notes, inspect the script, and pin to a
known-good version manually.

## Auto-merge surface

Three independent automations merge to `main` without human review:

- `update-linpeas.yml` (daily) — upstream `linpeas.sh` content.
- `update-flake-lock.yml` (weekly) — `nixpkgs` and other flake input revs.
- Renovate (weekly) — GitHub Action SHAs and the pinned Nix installer
  version.

Each is gated by CI (build success + SRI-hash integrity), not by content
review. A compromise of any upstream feed produces an attested release
within roughly 24 hours of upstream doing it. This is the documented and
accepted trust model for a thin wrapper repo — it matches the trust model
of `curl ... | bash`, with the addition of reproducible, hash-pinned
downloads and build-provenance attestations.

## Secrets

- `BUMP_PAT` — fine-grained personal access token used by
  `update-linpeas.yml` and `update-flake-lock.yml` to open and auto-merge
  bump PRs. Required scopes: this repository only, with `contents: write`
  and `pull-requests: write`. Rotate annually (or on suspected
  compromise). Stored as a repository secret.
