#!/usr/bin/env bash
# tests/check-renovate-config-validator.test.sh
#
# Failure-mode harness for scripts/check-renovate-config-validator.sh.
# Mirrors the pattern in tests/check-renovate-invariants.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-renovate-config-validator.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-renovate-config-validator"

failures=0

# @description Run the script with a fixture; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 valid, 1 rejected, 2 tooling error)
# @arg $4 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  RENOVATE_JSON_OVERRIDE="${FIXTURES}/${fixture}" \
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

# @description Point the override at a directory instead of a file. A
# directory fails the read for every user, root included — no mode bits
# stand between it and the could-not-run path — so this scenario proves
# the could-not-run path independent of permission bits.
# @arg $1 scenario name  @arg $2 expected stderr substring
function run_directory_scenario() {
  local -r name="$1"
  local -r expected_stderr="$2"
  local payload
  payload="$(mktemp --directory)"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  RENOVATE_JSON_OVERRIDE="${payload}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
  rm --recursive --force -- "${payload}"
}

# @description Point the override at a permission-denied file. Mode bits
# are no lever for root, so this scenario self-skips there;
# run_directory_scenario above covers the same could-not-run class for
# every user including root.
# @arg $1 scenario name  @arg $2 expected stderr substring
function run_unreadable_scenario() {
  local -r name="$1"
  local -r expected_stderr="$2"
  if [[ ${EUID} -eq 0 ]]; then
    printf 'SKIP: %s (running as root — mode bits are no lever)\n' "${name}"
    return 0
  fi
  local payload
  payload="$(mktemp)"
  printf '{}' >"${payload}"
  chmod 000 -- "${payload}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  RENOVATE_JSON_OVERRIDE="${payload}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
  chmod 600 -- "${payload}"
  rm --force -- "${payload}"
}

function main() {
  run_scenario 'good config passes' \
    'good.json' 0 ''
  run_scenario 'malformed JSON fails' \
    'bad-syntax.json' 1 ''
  run_scenario 'unknown schema key fails' \
    'bad-unknown-key.json' 1 ''
  run_scenario 'real repo renovate.json passes' \
    '../../../renovate.json' 0 ''
  # Absent, permission-denied, and non-regular-file overrides are three
  # different faults with three different sentences, so each gets its own
  # scenario rather than one shared "unreadable" label. An absent config
  # was never validated, so it cannot be reported as an invalid one.
  run_scenario 'absent config is a tooling error' \
    'no-such-config.json' 2 \
    'renovate schema: payload from RENOVATE_JSON_OVERRIDE not found'
  run_unreadable_scenario 'unreadable config is a tooling error' \
    'renovate schema: payload from RENOVATE_JSON_OVERRIDE is not readable'
  # A directory passes the existence and (typically) the readable checks,
  # so without the third guard it would reach the external validator and
  # come back misreported as a rejected config (exit 1) rather than a
  # could-not-run (exit 2).
  run_directory_scenario 'directory config is a tooling error, not a rejection' \
    'renovate schema: payload from RENOVATE_JSON_OVERRIDE could not be read'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
