#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck disable=SC2034  # fixture variables; the invocations are the artifact under test
x=$(gh attestation verify a.zip --repo rvenutolo/linPEAS-flake) y=$(gh attestation verify b.zip)
