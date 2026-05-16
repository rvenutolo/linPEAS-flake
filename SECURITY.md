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
Releases API `digest` field on each bump. Upstream PEASS-ng releases ship
no signatures (GPG, cosign, SLSA, etc.), so all integrity rests on the
pinned hash plus trust in GitHub's hosting.
