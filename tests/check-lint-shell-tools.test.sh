#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-lint-shell-tools.sh"

# The guard validates the CURRENT PATH. Run inside the dev shell (default or
# .#lint) every expected tool is present, so the check must exit 0.
got_exit=0
out="$(bash "${SCRIPT}" 2>&1)" || got_exit=$?
if ((got_exit != 0)); then
  printf 'FAIL: expected exit 0, got %d\n  output: %s\n' "${got_exit}" "${out}" >&2
  exit 1
fi
printf 'OK   all expected lint-shell tools present\n'

printf 'all tests passed\n'
