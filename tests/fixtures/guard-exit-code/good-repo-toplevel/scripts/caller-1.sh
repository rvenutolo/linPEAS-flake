#!/usr/bin/env bash
# Resolves the root through the helper.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(repo_toplevel)"
printf 'root at %s\n' "${REPO_ROOT}"
