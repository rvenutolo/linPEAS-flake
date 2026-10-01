#!/usr/bin/env bash
# Resolves the root through the helper.
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="${ROOT_OVERRIDE:-$(repo_toplevel)}"
printf 'root at %s\n' "${ROOT}"
