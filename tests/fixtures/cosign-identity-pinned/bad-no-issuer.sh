#!/usr/bin/env bash
set -Eeuo pipefail
cosign verify \
  --certificate-identity 'https://github.com/rvenutolo/linPEAS-flake/.github/workflows/release-on-bump.yml@refs/heads/main' \
  ghcr.io/rvenutolo/linpeas:latest
