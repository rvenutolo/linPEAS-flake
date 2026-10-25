#!/usr/bin/env bash
# tests/check-pin-diff-isolated.test.sh
#
# Failure-mode harness for scripts/check-pin-diff-isolated.sh.
# Fixture-driven: each scenario asserts exit code and output.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-pin-diff-isolated.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-pin-diff-isolated"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir, or an absolute path to a directory built at run
#   time
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local scripts_dir="${FIXTURES}/${fixture_dir}"
  if [[ ${fixture_dir} == /* ]]; then
    scripts_dir="${fixture_dir}"
  fi

  local actual_exit=0
  SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

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

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  run_scenario 'single canonical writer passes' \
    'good' 0 ''
  run_scenario 'multiple writers fail' \
    'bad-multi-writer' 1 'multiple scripts write'
  run_scenario 'wrong writer name fails' \
    'bad-wrong-writer' 1 'unexpected writer'
  run_scenario 'no writer fails' \
    'bad-no-writer' 1 'no script under'
  # Nothing to scan is a missing input, not a missing writer — the two
  # must not share an exit code.
  run_scenario 'absent scripts dir is a tooling error' \
    'no-such-fixture' 2 'scripts dir not found'
  # A second writer grep cannot read is not a tree with one writer: the
  # search could not examine it, so the run is a could-not-run.
  # Generated here because the fixture tree cannot hold an unreadable file.
  scratch="$(mktemp --directory)"
  # shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
  trap "chmod --recursive u+rwx -- '${scratch}'; rm --recursive --force -- '${scratch}'" EXIT
  cp --recursive -- "${FIXTURES}/bad-multi-writer" "${scratch}/unreadable-writer"
  chmod 000 -- "${scratch}/unreadable-writer/update-pin.sh"
  run_scenario 'unreadable second writer is a tooling error' \
    "${scratch}/unreadable-writer" 2 \
    "could not search ${scratch}/unreadable-writer for writers of linpeas-pin.json"
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
