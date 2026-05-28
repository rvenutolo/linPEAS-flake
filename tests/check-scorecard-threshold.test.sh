#!/usr/bin/env bash
# tests/check-scorecard-threshold.test.sh
#
# Failure-mode harness for scripts/check-scorecard-threshold.sh.
# Mirrors the pattern in tests/check-cliff-tag-pattern.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-scorecard-threshold.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/scorecard-threshold"

failures=0

# @description Run the script with a fixture on stdin; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 or 1)
# @arg $4 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  "${SCRIPT}" <"${FIXTURES}/${fixture}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

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

  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'all checks at 10 → exit 0, no stderr' \
    'all-10.json' 0 ''

  run_scenario 'one check at 9 → exit 1, names offender' \
    'one-9.json' 1 'Maintained'

  run_scenario 'multi-low → exit 1, names all offenders' \
    'multi-low.json' 1 'Webhooks'

  run_scenario 'malformed JSON → exit 1 under pipefail' \
    'malformed.json' 1 ''

  run_scenario 'empty stdin → exit 1 (no silent no-op)' \
    'empty.json' 1 'stdin was empty'

  if [[ ${failures} -gt 0 ]]; then
    printf '%d scenario(s) FAILED\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios PASS\n'
}

main "$@"
