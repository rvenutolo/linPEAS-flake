#!/usr/bin/env bash
set -Eeuo pipefail
cosign verify \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  ghcr.io/rvenutolo/linpeas:latest
