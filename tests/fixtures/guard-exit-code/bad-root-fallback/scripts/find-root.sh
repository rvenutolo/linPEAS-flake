#!/usr/bin/env bash
# A fallback reads the wrong tree instead of reporting the failure.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
printf 'root at %s\n' "${REPO_ROOT}"
