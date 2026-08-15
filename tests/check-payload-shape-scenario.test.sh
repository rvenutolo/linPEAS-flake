#!/usr/bin/env bash
# tests/check-payload-shape-scenario.test.sh
#
# Spec-driven harness for scripts/check-payload-shape-scenario.sh. Drives
# the lint against fixture scripts/ + tests/ roots via
# SCRIPTS_DIR_OVERRIDE + TESTS_DIR_OVERRIDE, then asserts it holds on the
# live tree.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-payload-shape-scenario.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/payload-shape-scenario"

failures=0

# ${1}=scenario name       ${2}=scripts dir  ${3}=tests dir
# ${4}=wanted exit         ${5}=wanted stderr substring ('' for none)
# ${6}=1 to run with LINT_ALLOW_EMPTY_SCAN set (default: unset)
function expect() {
  local -r name="$1" scripts_dir="$2" tests_dir="$3" want_exit="$4" want_msg="$5"
  local -r allow_empty="${6:-}"

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  LINT_ALLOW_EMPTY_SCAN="${allow_empty}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  local got_stderr
  got_stderr="$(cat -- "${stderr_file}")"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_stderr}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

function main() {
  # (a) GOOD: the covered subject's paired harness carries a scenario
  # asserting exit 2 against a malformed payload.
  expect 'a covered subject is clean' \
    "${FIXTURES}/covered/scripts" "${FIXTURES}/covered/tests" 0 ''

  # (b) BAD: the uncovered subject matches the predicate but its paired
  # harness never exercises the malformed-input path. Asserted against
  # the script-qualified message (not the bare template) so this
  # scenario's assertion does not also match the live-tree scenario's
  # output below, which reports the same template for a different
  # script.
  expect 'an uncovered subject is a violation' \
    "${FIXTURES}/uncovered/scripts" "${FIXTURES}/uncovered/tests" 1 \
    'check-gizmo.sh: no scenario asserting exit 2'

  # (c) GOOD: the same script as (b), but carrying a declared
  # payload-subject-exempt marker, so the missing scenario is not a
  # violation. TESTS_DIR points at a directory that does not exist, to
  # prove the exemption short-circuits before any harness is even
  # looked for.
  expect 'a declared exemption clears it' \
    "${FIXTURES}/exempt/scripts" "${FIXTURES}/exempt/tests-does-not-exist" 0 ''

  # (d) BAD: a payload-subject-exempt marker on a script the predicate
  # does not match at all — a stale exemption is drift, not a no-op.
  expect 'a marker on a non-subject script is a violation' \
    "${FIXTURES}/stale/scripts" "${FIXTURES}/stale/tests-does-not-exist" 1 \
    'carries a payload-subject-exempt marker but is not a subject'

  # (e) TOOLING: a scan root whose scripts match zero subjects. A clean
  # exit here would be indistinguishable from a scan that quietly
  # stopped recognizing every arm of the predicate.
  expect 'zero subjects is a could-not-run' \
    "${FIXTURES}/empty/scripts" "${FIXTURES}/empty/tests-does-not-exist" 2 \
    'scanned 0'

  # (f) TOOLING: ...and the documented override suppresses it, for a
  # scan root that deliberately holds no external-payload consumer.
  expect 'zero subjects passes when allowed' \
    "${FIXTURES}/empty/scripts" "${FIXTURES}/empty/tests-does-not-exist" 0 '' 1

  # (g) LIVE: run against the real tree. Every subject this batch gated
  # (bump-linpeas.sh, check-allowed-actions-api.sh,
  # check-flake-lock-provenance.sh, check-pin-digest-provenance.sh,
  # check-pre-commit-hooks-sha-parity.sh, check-protect-main.sh,
  # check-scorecard-threshold.sh, check-settings-posture.sh,
  # check-tag-protection.sh, gen-dashboard-data.sh) now carries a
  # malformed-payload scenario, and the four non-subjects carry their
  # exemption marker. inventory-action-pin-tags.sh is a genuine, newly
  # surfaced gap: its `gh api` payload flows straight into gh's own
  # `--jq` filter, whose failure already maps to the script's existing
  # API_FAILURE/exit-1 row rather than to a dedicated exit-2 shape gate,
  # so closing it means changing that script's error-handling shape —
  # out of scope here. Asserting on its own name (rather than the
  # generic uncovered-subject wording scenario (b) already asserts)
  # keeps this scenario's assertion from being interchangeable with (b).
  expect 'the live tree has one known, out-of-scope gap' \
    "${REPO_ROOT}/scripts" "${REPO_ROOT}/tests" 1 \
    'inventory-action-pin-tags.sh: no scenario asserting exit 2'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
