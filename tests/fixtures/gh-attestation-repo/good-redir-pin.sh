#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify a.zip 2>&1 --repo rvenutolo/linPEAS-flake
