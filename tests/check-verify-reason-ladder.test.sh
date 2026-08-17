#!/usr/bin/env bash
# tests/check-verify-reason-ladder.test.sh
#
# Failure-mode harness for scripts/check-verify-reason-ladder.sh.
#
# Each scenario is a self-contained miniature verify workflow plus the
# reason-token doc it is checked against, so one assertion fires per
# scenario and the expected message discriminates it from its siblings.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-verify-reason-ladder.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/verify-reason-ladder"

failures=0

# @description Run the script against one scenario; assert exit code and stderr.
# @arg $1 scenario directory name under FIXTURES/
# @arg $2 workflow file basename within that directory
# @arg $3 expected exit code (0, 1, or 2)
# @arg $4 expected stderr substring (empty string skips the check)
function expect() {
  local -r scenario="$1"
  local -r workflow="$2"
  local -r want_exit="$3"
  local -r want_msg="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  VERIFY_WORKFLOW_OVERRIDE="${FIXTURES}/${scenario}/${workflow}" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/${scenario}/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"

  if [[ ${got_exit} -ne ${want_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${scenario}" "${want_exit}" "${got_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${want_msg}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${scenario}" "${want_msg}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${scenario}" "${got_exit}"
  fi

  harness_assert_record "${scenario}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

# @description A reason-ladder-exempt marker on a step the attribution env
# already reads excuses nothing, and neither does one on the attribution
# step itself: assertion 1 skips the attribution step unconditionally and
# would have passed the referenced step regardless of the marker. Both
# arms are covered by the one fixture — 'step-alpha', which the env
# already reads via STEP_ALPHA, and 'attribute', the ladder's own step —
# so both diagnostics come from one invocation. They are asserted on one
# record via harness_assert_also rather than as two separate `expect`
# calls: driving the script twice against the same fixture would produce
# two byte-identical records asserting different substrings, which is
# exactly the collapsed-coverage shape the discrimination gate exists to
# catch.
function expect_unearned_exempt() {
  local -r scenario='bad-unearned-exempt'
  local -r referenced_msg='reason-ladder-exempt marker on step id step-alpha excuses nothing'
  local -r attribute_msg='reason-ladder-exempt marker on step id attribute excuses nothing'

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  VERIFY_WORKFLOW_OVERRIDE="${FIXTURES}/${scenario}/workflow.yml" \
    VERIFICATION_DOC_OVERRIDE="${FIXTURES}/${scenario}/verification.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${scenario}" "${referenced_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  harness_assert_also "${attribute_msg}"

  if [[ ${got_exit} -ne 1 ]]; then
    printf 'FAIL: %s — expected exit 1, got %d\n' "${scenario}" "${got_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${referenced_msg}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing the referenced-step diagnostic\n' "${scenario}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${attribute_msg}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing the attribution-step diagnostic\n' "${scenario}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${scenario}" "${got_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  expect 'good' 'workflow.yml' 0 ''

  expect 'bad-env-key-regex' 'workflow.yml' 1 \
    'is not a shell identifier'

  expect 'bad-missing-env' 'workflow.yml' 1 \
    'has no steps.<id>.outcome entry'

  expect 'bad-unread-env' 'workflow.yml' 1 \
    'is never read by the reason ladder'

  expect 'bad-undocumented-reason' 'workflow.yml' 1 \
    'is not documented in'

  expect 'bad-ladder-order' 'workflow.yml' 1 \
    'but the steps run in the opposite order'

  expect 'exempt-step' 'workflow.yml' 0 ''

  expect_unearned_exempt

  expect 'malformed' 'bad-malformed.yml' 2 \
    'could not evaluate'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
