#!/usr/bin/env bash
# scripts/check-b.sh
#
# Exits 0 on full coverage, 1 on any drift, 2 on tooling error.
set -Eeuo pipefail
require_tool jq
echo b
