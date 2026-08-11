#!/usr/bin/env bash
# tests/check-orphan-invariants.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-orphan-invariants.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-orphan-invariants"

failures=0

function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  INVARIANT_INDEX_OVERRIDE="${FIXTURES}/${fixture_dir}/index.md" \
    DOCS_ROOT_OVERRIDE="${FIXTURES}/${fixture_dir}/docs" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"
  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'good tree passes' 'good' 0 ''
  run_scenario 'orphan index link fails' \
    'bad-orphan-link' 1 '[orphan-link]'
  run_scenario 'unreferenced doc fails' \
    'bad-unreferenced-doc' 1 '[unreferenced-doc]'
  # An absent index is a missing input, not a docs/index divergence: the
  # tooling code keeps it out of the drift bucket.
  run_scenario 'absent index is a tooling error' \
    'no-such-fixture' 2 'invariant index not found'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
