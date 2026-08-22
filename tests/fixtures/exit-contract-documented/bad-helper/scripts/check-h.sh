#!/usr/bin/env bash
# scripts/check-h.sh
#
# Exits 0 on full coverage, 1 on any drift.
set -Eeuo pipefail
glob_into files 'workflow YAML' '.github/workflows/*.yml'
echo h
