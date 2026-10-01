#!/usr/bin/env bash
# readonly returns its own status, so the 2 inside the default
# expansion is lost.
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="${ROOT_OVERRIDE:-$(repo_toplevel)}"
printf 'root at %s\n' "${ROOT}"
