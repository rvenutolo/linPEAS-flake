#!/usr/bin/env bash
# tests/check-allowed-actions-api.test.sh
#
# Failure-mode harness for scripts/check-allowed-actions-api.sh.
# Mirrors tests/check-settings-posture.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-allowed-actions-api.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-allowed-actions-api"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
# @arg $5 selected-actions payload filename under the fixture subdir
#   (default selected-actions.json) — a scenario whose payload must stay
#   invalid JSON names a non-.json file here so prettier's `*.json`
#   include never touches it
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r selected_file="${5:-selected-actions.json}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SELECTED_ACTIONS_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/${selected_file}" \
    ALLOWED_ACTIONS_DOC_OVERRIDE="${FIXTURES}/${fixture_dir}/allowed-actions.md" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

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

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# Points one override at an unreadable payload while the other stays a
# good fixture, so a scenario proves the could-not-run path fires on the
# override under test and nowhere else. Mode bits are no lever for root,
# so this scenario is skipped there.
# @arg $1 scenario name
# @arg $2 override variable to point at the unreadable payload
# @arg $3 expected stderr substring
function run_unreadable_scenario() {
  local -r name="$1" override_var="$2" expected_stderr="$3"
  if [[ ${EUID} -eq 0 ]]; then
    printf 'SKIP: %s (running as root — mode bits are no lever)\n' "${name}"
    return 0
  fi
  local payload
  payload="$(mktemp)"
  printf 'unreadable' >"${payload}"
  chmod 000 -- "${payload}"

  local selected_override="${FIXTURES}/good/selected-actions.json"
  local doc_override="${FIXTURES}/good/allowed-actions.md"
  case "${override_var}" in
  SELECTED_ACTIONS_JSON_OVERRIDE) selected_override="${payload}" ;;
  ALLOWED_ACTIONS_DOC_OVERRIDE) doc_override="${payload}" ;;
  esac

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SELECTED_ACTIONS_JSON_OVERRIDE="${selected_override}" \
    ALLOWED_ACTIONS_DOC_OVERRIDE="${doc_override}" \
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
  local -r multi='multiple drifts surface every one'

  run_scenario 'matching fixtures pass' \
    'good' 0 ''
  run_scenario 'extra vendor on API fails' \
    'bad-extra-vendor' 1 'patterns_allowed drift: extra on API: attacker/*'
  run_scenario 'vendor missing from API fails' \
    'bad-missing-vendor' 1 'patterns_allowed drift: missing on API: peter-evans/*'
  run_scenario 'github_owned_allowed false fails' \
    'bad-github-owned-false' 1 'github_owned_allowed drift: got false, want true'
  run_scenario 'verified_allowed true fails' \
    'bad-verified-true' 1 'verified_allowed drift: got true, want false'
  run_scenario "${multi}" \
    'bad-multiple' 1 '3 allowlist drift(s)'
  # Without the doc there is no expected side to compare against, so the
  # comparison never happens: the could-not-run code, not a drift report
  # that would point at the live API state.
  run_scenario 'missing allowlist doc could not run' \
    'does-not-exist' 2 'allowed-actions doc not found'
  # A malformed selected-actions payload is a could-not-run, not drift
  # or a raw jq crash: each scenario reuses the good allowlist doc and
  # varies only the API payload, naming the source kind rather than the
  # fixture path.
  run_scenario 'empty selected-actions payload is a tooling error' \
    'bad-selected-empty' 2 'empty payload from SELECTED_ACTIONS_JSON_OVERRIDE'
  run_scenario 'selected-actions payload that is not JSON is a tooling error' \
    'bad-selected-not-json' 2 \
    'payload from SELECTED_ACTIONS_JSON_OVERRIDE is not valid JSON' \
    'selected-payload.txt'
  run_scenario 'boolean-typed selected-actions payload is a tooling error' \
    'bad-selected-wrong-type' 2 \
    'unexpected payload shape from SELECTED_ACTIONS_JSON_OVERRIDE: payload is boolean, want object'

  # This is the reported defect: an unreadable override payload must
  # report a could-not-run (exit 2), not a raw `cat` failure under exit 1.
  run_unreadable_scenario 'unreadable selected-actions override is a tooling error, not drift' \
    SELECTED_ACTIONS_JSON_OVERRIDE \
    'payload from SELECTED_ACTIONS_JSON_OVERRIDE is not readable'
  # The markdown doc does not go through the JSON reader, so its
  # unreadable case gets its own sentence beside the existing not-found
  # guard rather than the JSON reader's.
  run_unreadable_scenario 'unreadable allowed-actions doc override is a tooling error, not drift' \
    ALLOWED_ACTIONS_DOC_OVERRIDE \
    'allowed-actions doc is not readable:'

  # bad-multiple must surface every drift in a single run — count drift
  # lines. It carries the good posture's booleans (a boolean has only
  # one wrong value, which the single-drift boolean scenarios above
  # already claim as their asserted substring; reusing it here would
  # make this scenario's output byte-for-byte overlap with theirs on
  # that line) and instead derives all three drifts from
  # `patterns_allowed`: two vendors present on the API but absent from
  # the doc, one vendor declared in the doc but absent from the API —
  # none of which the single-vendor scenarios above name.
  local stderr_file
  stderr_file="$(mktemp)"
  SELECTED_ACTIONS_JSON_OVERRIDE="${FIXTURES}/bad-multiple/selected-actions.json" \
    ALLOWED_ACTIONS_DOC_OVERRIDE="${FIXTURES}/bad-multiple/allowed-actions.md" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || true
  local drift_lines
  drift_lines="$(grep --count -- ' drift: ' "${stderr_file}" || true)"
  if ((drift_lines < 3)); then
    printf 'FAIL: bad-multiple — expected >=3 drift lines, got %d\n' \
      "${drift_lines}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: bad-multiple surfaces %d drift lines in one run\n' \
      "${drift_lines}"
  fi
  # Not recorded: this re-runs the fixture the scenario above already
  # recorded, asserting a second property of the same output rather than a
  # distinct scenario.
  rm --force -- "${stderr_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
