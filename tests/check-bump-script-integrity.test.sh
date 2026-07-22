#!/usr/bin/env bash
# tests/check-bump-script-integrity.test.sh
#
# Failure-mode harness for scripts/check-bump-script-integrity.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-bump-script-integrity.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-bump-script-integrity"

failures=0

# @arg $1 scenario name
# @arg $2 fixture basename (under FIXTURES)
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  BUMP_SCRIPT_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'all guards present passes' \
    'good.sh' 0 ''
  run_scenario 'missing url-prefix guard fails' \
    'bad-no-url-prefix.sh' 1 'url prefix'
  run_scenario 'missing digest cross-check fails' \
    'bad-no-digest.sh' 1 'digest'
  run_scenario 'truncating pin write fails' \
    'bad-truncating-write.sh' 1 'atomic'

  # Live self-scan: the real bump script must retain all guards.
  local stderr_file
  stderr_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  if ((actual_exit != 0)); then
    printf 'FAIL: live scripts/bump-linpeas.sh is missing a guard:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live scripts/bump-linpeas.sh retains all guards\n'
  fi
  rm --force -- "${stderr_file}"

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
