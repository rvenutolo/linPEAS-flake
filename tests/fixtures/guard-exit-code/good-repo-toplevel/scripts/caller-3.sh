#!/usr/bin/env bash
# Resolves the root through the helper only when the override is unset,
# then declares it on a line of its own.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT="${ROOT_OVERRIDE:-$(repo_toplevel)}"
readonly ROOT
printf 'root at %s\n' "${ROOT}"
