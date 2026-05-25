#!/usr/bin/env bash
# tests/check-hammer-shim-parity.test.sh
#
# Failure-mode harness for scripts/check-hammer-shim-parity.sh.
# Mirrors the pattern in tests/check-pre-commit-hooks-sha-parity.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-hammer-shim-parity.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-hammer-shim-parity"

failures=0

# @description Run the script with a fixture pair; assert exit code +
# stderr substring.
# @arg $1 scenario name
# @arg $2 fixture subdir under FIXTURES
# @arg $3 expected exit code (0, 1, or 2)
# @arg $4 expected stderr substring (empty skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  FLAKE_NIX_OVERRIDE="${FIXTURES}/${fixture_dir}/flake.nix" \
    HAMMER_SHIM_OVERRIDE="${FIXTURES}/${fixture_dir}/hammer-shim.nix" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'matching derivations pass' \
    'good' 0 ''
  run_scenario 'drifted derivation fails' \
    'bad-drift' 1 'parity drift'
  run_scenario 'missing marker fails extraction' \
    'bad-no-marker' 2 'could not extract'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
