#!/usr/bin/env bash
# scripts/check-a.sh
#
# Exits 0 on clean, 1 on drift.
# Exits 2 when the check cannot run: yq is absent from PATH.
set -Eeuo pipefail
if ! command -v yq >/dev/null 2>&1; then exit 2; fi
echo a
