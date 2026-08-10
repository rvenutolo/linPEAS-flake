#!/usr/bin/env bash
# tests/check-pre-commit-hooks-sha-parity.test.sh
#
# Failure-mode harness for scripts/check-pre-commit-hooks-sha-parity.sh.
# Mirrors the pattern in tests/check-tag-protection.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-pre-commit-hooks-sha-parity.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-pre-commit-hooks-sha-parity"

failures=0

# @description Run the script with a fixture pair; assert exit code +
# stderr substring.
# @arg $1 scenario name
# @arg $2 fixture subdir under FIXTURES
# @arg $3 expected exit code (0 or 1)
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
    FLAKE_LOCK_OVERRIDE="${FIXTURES}/${fixture_dir}/flake.lock" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"

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
  run_scenario 'matched SHAs pass' \
    'good' 0 ''
  run_scenario 'SHA mismatch fails' \
    'bad-mismatch' 1 'SHA drift'
  run_scenario 'missing URL fails' \
    'bad-no-url' 1 'no github:cachix/git-hooks.nix'
  run_scenario 'missing lock node fails' \
    'bad-no-lock-node' 1 'no nodes'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
