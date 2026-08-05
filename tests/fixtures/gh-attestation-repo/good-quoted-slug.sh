#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify pin.json --repo "rvenutolo/linPEAS-flake"
