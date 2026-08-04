#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify evil.json # --repo rvenutolo/linPEAS-flake
