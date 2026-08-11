#!/usr/bin/env bash
# tests/check-renovate-markers-matched.test.sh
#
# Failure-mode harness for scripts/check-renovate-markers-matched.sh.
# Mirrors the pattern in tests/check-renovate-invariants.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-renovate-markers-matched.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/renovate-markers"

failures=0

# @description Run the script against a fixture dir; assert exit, stderr,
# and the coverage summary the clean path prints to stdout.
# @arg $1 scenario name
# @arg $2 fixture dir name under FIXTURES
# @arg $3 expected exit code (0 live, 1 dead marker, 2 tooling error)
# @arg $4 expected stderr substring (empty string skips the check)
# @arg $5 expected stdout substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r expected_stdout="${5:-}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  RENOVATE_JSON_OVERRIDE="${FIXTURES}/${fixture}/renovate.json" \
    SCAN_ROOT="${FIXTURES}/${fixture}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi

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
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description Run the script against the live repo (no overrides); assert
# pass, and that the summary names a marked file the tree actually carries
# together with the manager that matched it. Keys on the leading, stable
# part of that entry — never on how many markers the tree holds, which
# grows with the repository.
function run_live_tree() {
  local -r expected_stdout='renovate markers: all live; matched .github/actions/setup-nix/action.yml by customManagers['

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record 'live tree' "${expected_stdout}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: live tree has dead renovate markers (exit %d)\n' "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: live tree — stdout missing %q\n' "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live tree — no dead renovate markers\n'
  fi
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  # The clean scenarios differ only in which manager matched which file,
  # so each asserts the summary entry naming its own pair.
  run_scenario 'inline marker covered' \
    'covered-inline' 0 '' \
    'renovate markers: all live; matched app.yml by customManagers[0]'
  run_scenario 'above-style marker covered' \
    'covered-above' 0 '' \
    'renovate markers: all live; matched install.sh by customManagers[0]'
  # The two ways a marker dies call for different edits to renovate.json,
  # so each scenario asserts the reason its own defect produced rather
  # than the bare diagnostic both would print.
  run_scenario 'matchString matches no line fails' \
    'dead-regex' 1 'dead renovate marker: app.yml:1 (scoped by customManagers[0] but no matchString matches a line)'
  run_scenario 'marker file outside all filePatterns fails' \
    'dead-path' 1 'dead renovate marker: sub/app.yml:1 (no managerFilePattern scopes this path)'
  run_scenario 'all install-URL prefix variants covered' \
    'prefix-variants' 0 '' \
    'renovate markers: all live; matched matrix.yml by customManagers[0]'
  run_scenario 'empty managerFilePatterns covers nothing' \
    'empty-file-patterns' 1 'dead renovate marker: app.yml:1 (no managerFilePattern scopes this path)'
  run_scenario 'non-array managerFilePatterns is a tooling error' \
    'bad-file-patterns-type' 2 'could not read customManagers[0].managerFilePatterns'
  run_scenario 'non-array matchStrings is a tooling error' \
    'bad-match-strings-type' 2 'could not read customManagers[0].matchStrings'
  # An absent config leaves every marker unjudged; calling that a dead
  # marker would blame the markers for a missing input.
  run_scenario 'absent config is a tooling error' \
    'no-such-fixture' 2 'renovate config not found'
  run_live_tree
  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall scenarios passed\n'
}

main "$@"
