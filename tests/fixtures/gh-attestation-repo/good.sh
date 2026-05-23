#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify "oci://ghcr.io/rvenutolo/linpeas@sha256:deadbeef" --repo rvenutolo/linPEAS-flake
gh attestation verify pin.json \
  --repo rvenutolo/linPEAS-flake
