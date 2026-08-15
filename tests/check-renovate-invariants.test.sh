#!/usr/bin/env bash
# tests/check-renovate-invariants.test.sh
#
# Failure-mode harness for scripts/check-renovate-invariants.sh.
# Mirrors the pattern in tests/check-tag-protection.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-renovate-invariants.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/renovate-invariants"

failures=0

# @description Run the script with a fixture; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 intact, 1 drift, 2 tooling error)
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

function main() {
  run_scenario 'good config passes' \
    'good.json' 0 ''
  run_scenario 'missing minimumReleaseAge fails' \
    'bad-no-min-age.json' 1 'minimumReleaseAge not set'
  run_scenario 'top-level automerge fails' \
    'bad-toplevel-automerge.json' 1 'top-level automerge'
  run_scenario 'missing pinDigests fails' \
    'bad-no-pin-digests.json' 1 'pinDigests'
  run_scenario 'extends missing helpers:pinGitHubActionDigests fails' \
    'bad-no-extends-pin.json' 1 'helpers:pinGitHubActionDigests'
  # No config read means no invariant was checked; that is a missing
  # input, not a dropped invariant.
  run_scenario 'absent config is a tooling error' \
    'no-such-config.json' 2 'renovate config not found'
  # A malformed payload is a could-not-run, not drift. Every read below
  # the gate assumes a shape the config file does not guarantee, and a
  # jq parse failure inverted by `if !` reads as a dropped invariant —
  # sending a maintainer after a setting nobody touched. Each scenario
  # names the fault the gate rejected, never the fixture that carried it.
  run_scenario 'malformed payload that is not JSON is a tooling error' \
    'bad-not-json.json' 2 'payload from RENOVATE_JSON_OVERRIDE is not valid JSON'
  run_scenario 'empty payload is a tooling error' \
    'bad-empty-payload.json' 2 'empty payload from RENOVATE_JSON_OVERRIDE'
  run_scenario 'array-typed payload is a tooling error' \
    'bad-top-level-array.json' 2 \
    'unexpected payload shape from RENOVATE_JSON_OVERRIDE: payload is array, want object'
  run_scenario 'string-typed extends is a tooling error' \
    'bad-extends-type.json' 2 \
    'unexpected payload shape from RENOVATE_JSON_OVERRIDE: .extends is string, want array'
  run_scenario 'non-object packageRules entry is a tooling error' \
    'bad-package-rules-item-type.json' 2 \
    'unexpected payload shape from RENOVATE_JSON_OVERRIDE: a packageRules entry is not an object'
  run_scenario 'number-typed minimumReleaseAge is a tooling error' \
    'bad-min-age-type.json' 2 \
    'unexpected payload shape from RENOVATE_JSON_OVERRIDE: .minimumReleaseAge is number, want string'
  run_scenario 'string-typed packageRules is a tooling error' \
    'bad-package-rules-type.json' 2 \
    'unexpected payload shape from RENOVATE_JSON_OVERRIDE: .packageRules is string, want array'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
