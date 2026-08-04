#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify evil.json --predicate-type "--repo rvenutolo/linPEAS-flake"
