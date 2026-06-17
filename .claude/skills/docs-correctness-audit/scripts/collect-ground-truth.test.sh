#!/usr/bin/env bash
# Test harness for collect-ground-truth.sh sweeps. Run from anywhere.
set -Eeuo pipefail
IFS=$'\n\t'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR="${HERE}/collect-ground-truth.sh"
# shellcheck disable=SC2034  # used by Tasks 2 and 3 fixture checks
REAL_REPO="$(git -C "${HERE}" rev-parse --show-toplevel)"
fails=0
check() { # $1=label $2=condition-already-evaluated(0/1)
  if [[ $2 -eq 0 ]]; then printf 'PASS: %s\n' "$1"; else
    printf 'FAIL: %s\n' "$1"
    fails=$((fails + 1))
  fi
}

# --- sourcing must not auto-run main ---
# shellcheck disable=SC1090  # COLLECTOR path is dynamic by design
src_out="$(
  source "${COLLECTOR}" 2>&1
  printf '__SOURCED__'
)"
case "${src_out}" in
*"===== FLAKE OUTPUTS"*) check "sourcing does not auto-run main" 1 ;;
*) check "sourcing does not auto-run main" 0 ;;
esac

# (further fixture-based checks added in Tasks 2 and 3)

if [[ ${fails} -ne 0 ]]; then
  printf '\n%d FAILED\n' "${fails}"
  exit 1
fi
printf '\nALL PASSED\n'
