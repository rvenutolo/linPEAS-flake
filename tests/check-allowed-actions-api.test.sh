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
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  SELECTED_ACTIONS_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/selected-actions.json" \
    ALLOWED_ACTIONS_DOC_OVERRIDE="${FIXTURES}/${fixture_dir}/allowed-actions.md" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

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

  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"
  rm --force -- "${stderr_file}"
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

  # bad-multiple must surface every drift (github_owned, verified, extra
  # vendor) in a single run — count drift lines. Its offending value for
  # each key differs from the single-drift fixture covering that key, so
  # no single-drift assertion can be satisfied by this fixture's output:
  # the booleans arrive absent (the script reads them as `null`) rather
  # than flipped, and the unlisted vendor pattern is its own.
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
