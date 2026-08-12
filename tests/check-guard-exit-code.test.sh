#!/usr/bin/env bash
# tests/check-guard-exit-code.test.sh
#
# Failure-mode harness for scripts/check-guard-exit-code.sh.
#
# Each scenario is a miniature scripts/ tree carrying exactly one guard
# shape, so the expected message names the shape under test and nothing
# a sibling scenario also prints.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-guard-exit-code.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/guard-exit-code"

failures=0

# @description Run the lint over one fixture tree; assert exit code and
# the expected output substring.
# @arg $1 scenario name
# @arg $2 fixture subdir (its scripts/ subtree is the scan root)
# @arg $3 expected exit
# @arg $4 expected substring across stdout+stderr (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_msg="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture_dir}/scripts" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'output was:\n' >&2
    cat -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" \
      "${stdout_file}" "${stderr_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    printf 'output was:\n' >&2
    cat -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  run_scenario 'tool guard exiting 1 is a hit' \
    'bad-tool-guard' 1 '! command -v yq >/dev/null 2>&1'
  # shellcheck disable=SC2016 # the asserted substring is the fixture's literal guard text
  run_scenario 'input-file guard exiting 1 is a hit' \
    'bad-file-guard' 1 '[[ ! -f ${doc} ]]'
  # Absence mixed with a content predicate under `||` reaches the branch
  # without anything being missing, so the exit stays a drift verdict.
  run_scenario 'compound availability-plus-content test is not a hit' \
    'good-compound-test' 0 '1 script(s) scanned, 0 exemption(s)'
  run_scenario 'rationale-bearing exemption is counted, not flagged' \
    'good-exempted' 0 '1 script(s) scanned, 1 exemption(s)'
  # An empty rationale is its own finding: silently honoring it would
  # make the marker a way to opt out of stating a reason.
  run_scenario 'exemption without a rationale is a hit' \
    'bad-exemption-no-rationale' 1 'marker carries no rationale'
  run_scenario 'guards already exiting 2 pass' \
    'good-clean' 0 '2 script(s) scanned, 0 exemption(s)'
  # Nothing to scan is a missing input, not a clean tree — the two must
  # not share an exit code.
  run_scenario 'absent scripts dir is a tooling error' \
    'no-such-fixture' 2 'scripts dir not found'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
