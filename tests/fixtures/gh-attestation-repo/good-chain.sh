#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify a.json --repo rvenutolo/linPEAS-flake && gh attestation verify b.json --repo rvenutolo/linPEAS-flake
