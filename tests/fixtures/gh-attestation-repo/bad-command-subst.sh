#!/usr/bin/env bash
set -Eeuo pipefail
out=$(gh attestation verify artifact.zip)
echo "${out}"
