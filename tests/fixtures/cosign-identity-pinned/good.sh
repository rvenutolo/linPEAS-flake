#!/usr/bin/env bash
set -Eeuo pipefail
cosign verify \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/rvenutolo/linpeas:latest

nix run nixpkgs#cosign -- verify \
  --certificate-identity-regexp '^https://github.com/rvenutolo/.+@refs/heads/main$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/rvenutolo/linpeas:latest
