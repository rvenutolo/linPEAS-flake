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

# @description Run the script with a fixture; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 pass, 1 drift, 2 tooling error)
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
  RULESET_JSON_OVERRIDE="${FIXTURES}/${fixture}" \
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
  run_scenario 'good ruleset passes' \
    'good-ruleset.json' 0 ''
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
  run_scenario 'fallback glob pattern passes' \
    'good-fallback-glob.json' 0 ''
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
