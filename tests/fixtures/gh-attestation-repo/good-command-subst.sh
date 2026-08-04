#!/usr/bin/env bash
set -Eeuo pipefail
out=$(gh attestation verify a.zip --repo rvenutolo/linPEAS-flake)
echo "${out}"
