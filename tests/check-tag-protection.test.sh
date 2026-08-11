#!/usr/bin/env bash
# tests/check-tag-protection.test.sh
#
# Failure-mode harness for scripts/check-tag-protection.sh.
# Mirrors the pattern in tests/check-pr-workflows-no-secrets.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-tag-protection.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/tag-protection"

failures=0

# @description Render the posture summary the lint prints on stdout when
# the ruleset matches, so a passing scenario states the posture it expects
# to have been verified rather than repeating the format string.
# @arg $1 rules in the ruleset  @arg $2 bypass actors
# @arg $3 include patterns  @arg $4 which ref pattern matched
function summary() {
  printf 'tag-protection: release-tag-protection verified — %d rule(s) in the ruleset, %d bypass actor(s), %d include pattern(s); ref match: %s' \
    "$1" "$2" "$3" "$4"
}

# @description Run the script with a fixture; assert exit code, stderr,
# and the posture summary printed on stdout.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 pass, 1 drift, 2 tooling error)
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
  RULESET_JSON_OVERRIDE="${FIXTURES}/${fixture}" \
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

function main() {
  run_scenario 'good ruleset passes' \
    'good-ruleset.json' 0 '' \
    "$(summary 3 0 1 'pin-version pattern refs/tags/[0-9]{8}-[0-9a-f]{7,40}')"
  # Asserted through the have-list: the bare `missing rule: deletion` prefix
  # also opens the empty-rules diagnostic below, so it cannot tell a ruleset
  # that dropped one rule from one that reports no rules at all.
  run_scenario 'missing deletion rule fails' \
    'bad-no-deletion-rule.json' 1 'missing rule: deletion (have: update'
  run_scenario 'disabled enforcement fails' \
    'bad-disabled.json' 1 'enforcement drift:'
  run_scenario 'wrong include pattern fails' \
    'bad-wrong-pattern.json' 1 'ref_name.include does not contain expected pattern'
  run_scenario 'non-empty bypass_actors fails' \
    'bad-bypass-actors.json' 1 'bypass_actors non-empty'
  # Same posture as the good ruleset in every other respect, so only the
  # named ref match separates the two passing runs.
  run_scenario 'fallback glob pattern passes' \
    'good-fallback-glob.json' 0 '' \
    "$(summary 3 0 1 'fallback glob refs/tags/**')"
  run_scenario 'wrong ruleset name fails' \
    'bad-name-drift.json' 1 'name drift'
  run_scenario 'wrong target fails' \
    'bad-target-drift.json' 1 'target drift'
  run_scenario 'empty rules list is drift, not a tooling error' \
    'bad-rules-empty.json' 1 'missing rule: deletion (have: )'
  run_scenario 'non-array rules is a tooling error' \
    'bad-rules-wrong-type.json' 2 \
    'release-tag-protection ruleset: could not read .rules[].type'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
