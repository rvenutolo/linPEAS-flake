#!/usr/bin/env bash
# tests/check-scorecard-threshold.test.sh
#
# Failure-mode harness for scripts/check-scorecard-threshold.sh.
# Mirrors the pattern in tests/check-cliff-tag-pattern.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-scorecard-threshold.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/scorecard-threshold"

work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

failures=0

# @description Run the script with a fixture on stdin; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES, or an absolute path to a
#   payload built outside FIXTURES (e.g. under $work) for content that
#   cannot be committed as a tracked fixture
# @arg $3 expected exit code (0 or 1)
# @arg $4 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local fixture_path="${FIXTURES}/${fixture}"
  [[ ${fixture} == /* ]] && fixture_path="${fixture}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  "${SCRIPT}" <"${fixture_path}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
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
  run_scenario 'all checks at 10 → exit 0, no stderr' \
    'all-10.json' 0 ''

  run_scenario 'one check at 9 → exit 1, names offender' \
    'one-9.json' 1 'Maintained: 9'

  run_scenario 'multi-low → exit 1, names all offenders' \
    'multi-low.json' 1 'Webhooks'

  # A malformed stdin payload is a could-not-run, not a threshold
  # verdict of either polarity — never exit 0 as a fabricated clean
  # pass, and never exit 1 as though a check actually scored low.
  run_scenario 'unparsable JSON is a tooling error' \
    'malformed.json' 2 'is not valid JSON'

  # Whitespace-only stdin is the sharpest case: unguarded, it reads to
  # `jq '.checks[]'` as zero documents and the script exits 0 as if
  # every included check scored 10 — a clean pass fabricated from no
  # data at all. Built inline rather than as a tracked fixture: a
  # whitespace-only file on disk cannot satisfy this tree's own
  # trim-trailing-whitespace convention.
  local whitespace_payload="${work}/whitespace-payload"
  printf '   \n\t \n' >"${whitespace_payload}"
  run_scenario 'whitespace-only stdin is a tooling error' \
    "${whitespace_payload}" 2 'empty payload from stdin'

  run_scenario 'boolean-typed payload is a tooling error' \
    'bool.json' 2 'unexpected payload shape from stdin: payload is boolean, want object'

  # A `.checks` array of scalars passes a gate that stops at the array
  # and then kills the `.score` read with jq's own exit 5, outside the
  # convention. Built inline: a tracked fixture of this shape reads as a
  # scorecard payload rather than as the shape probe it is.
  local scalar_checks_payload="${work}/scalar-checks-payload.json"
  printf '{"checks": ["not-an-object"]}\n' >"${scalar_checks_payload}"
  run_scenario 'non-object .checks entry is a tooling error' \
    "${scalar_checks_payload}" 2 'a .checks entry is not an object'

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '%d scenario(s) FAILED\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios PASS\n'
}

main "$@"
