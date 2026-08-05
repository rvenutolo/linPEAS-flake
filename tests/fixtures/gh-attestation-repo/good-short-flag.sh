#!/usr/bin/env bash
set -Eeuo pipefail
gh attestation verify a.zip -R rvenutolo/linPEAS-flake
