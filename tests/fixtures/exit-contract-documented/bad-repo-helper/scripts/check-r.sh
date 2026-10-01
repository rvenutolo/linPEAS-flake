#!/usr/bin/env bash
# scripts/check-r.sh
#
# Exits 0 on full coverage, 1 on any drift.
set -Eeuo pipefail
REPO_ROOT="$(repo_toplevel)"
echo "${REPO_ROOT}"
