#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify evil.json; echo "always pass --repo rvenutolo/linPEAS-flake"
