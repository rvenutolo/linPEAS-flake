#!/usr/bin/env bash
# A marker with no rationale does not excuse a masked helper call.
set -Eeuo pipefail
IFS=$'\n\t'

readonly ROOT="${ROOT_OVERRIDE:-$(repo_toplevel)}" # exit-code-exempt:
printf 'root at %s\n' "${ROOT}"
