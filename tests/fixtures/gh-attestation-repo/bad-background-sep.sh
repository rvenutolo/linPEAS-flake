#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify evil.json & echo "--repo rvenutolo/linPEAS-flake"
