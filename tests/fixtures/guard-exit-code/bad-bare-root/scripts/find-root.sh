#!/usr/bin/env bash
# Resolves the root with a bare lookup, so outside a work tree the
# script ends with git's own status.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
printf 'root at %s\n' "${REPO_ROOT}"
