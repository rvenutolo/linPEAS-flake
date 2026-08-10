#!/usr/bin/env bash
# tests/check-flake-lock-provenance.test.sh
#
# Failure-mode harness for scripts/check-flake-lock-provenance.sh.
# Drives the check entirely off fixture files via the BASE_LOCK_FILE /
# HEAD_LOCK_FILE env overrides, so no git history is touched.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-flake-lock-provenance.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-flake-lock-provenance"

failures=0

# @arg $1 scenario name
# @arg $2 head fixture basename
# @arg $3 expected exit
# @arg $4 expected stderr/stdout substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r head="$2"
  local -r expected_exit="$3"
  local -r expected_msg="$4"

  local out_file
  out_file="$(mktemp)"

  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/base.lock" \
    HEAD_LOCK_FILE="${FIXTURES}/${head}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${out_file}"
}

# @arg $1 scenario name ; missing base => operational error (exit 2)
function run_missing_base() {
  local -r name="$1"
  local out_file
  out_file="$(mktemp)"
  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/does-not-exist.lock" \
    HEAD_LOCK_FILE="${FIXTURES}/base.lock" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit 2)\n' "${name}"
  fi
  rm --force -- "${out_file}"
}

# @arg $1 scenario name  @arg $2 head fixture  @arg $3 expected exit
# @arg $4 expected output substring (empty skips)
# Same as run_scenario but against the follows-shaped base lock.
function run_follows_scenario() {
  local -r name="$1" head="$2" expected_exit="$3" expected_msg="$4"
  local out_file
  out_file="$(mktemp)"
  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/base-follows.lock" \
    HEAD_LOCK_FILE="${FIXTURES}/${head}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --force -- "${out_file}"
}

function main() {
  run_scenario 'routine bump passes' 'head-routine.lock' 0 'provenance OK'
  run_scenario 'top-level owner change fails' 'head-toplevel-owner.lock' 1 'alpha'
  run_scenario 'top-level type change fails' 'head-toplevel-type.lock' 1 'alpha'
  run_scenario 'top-level input added fails' 'head-toplevel-added.lock' 1 'added'
  run_scenario 'top-level input removed fails' 'head-toplevel-removed.lock' 1 'removed'
  run_scenario 'transitive repoint fails' 'head-transitive-repoint.lock' 1 'gamma'
  run_scenario 'transitive node added tolerated' 'head-transitive-added.lock' 0 'provenance OK'
  run_scenario 'transitive node removed tolerated' 'head-transitive-removed.lock' 0 'provenance OK'
  run_scenario 'garbage head json errors' 'head-garbage.lock' 2 ''
  run_scenario 'top-level rename same source' 'head-toplevel-renamed-same.lock' 0 'provenance OK'
  run_scenario 'top-level rename + repoint fails' 'head-toplevel-renamed-repoint.lock' 1 'alpha'
  run_missing_base 'missing base errors'

  run_follows_scenario 'follows routine bump passes' 'head-follows-routine.lock' 0 'provenance OK'
  run_follows_scenario 'string-to-array repoint fails' 'head-follows-string-to-array.lock' 1 'gamma'
  run_follows_scenario 'array-to-array repoint fails' 'head-follows-array-change.lock' 1 'beta'
  run_follows_scenario 'string-to-array same source passes' 'head-follows-string-to-array-same.lock' 0 'provenance OK'
  run_follows_scenario 'dangling follows path fails' 'head-follows-dangling.lock' 1 'unresolvable'
  run_follows_scenario 'cyclic follows fails' 'head-follows-cycle.lock' 1 'unresolvable'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
