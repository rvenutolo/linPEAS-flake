#!/usr/bin/env bash
# tests/sbom-diff.test.sh
#
# Failure-mode + golden-output harness for scripts/sbom-diff.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/sbom-diff.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/sbom-diff"

failures=0

# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 expected stderr substring (empty skips)
# @arg $@ rest passed verbatim to script
function run_failure_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expected_stderr="$3"
  shift 3

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  "${SCRIPT}" "$@" >/dev/null 2>"${stderr_file}" || actual_exit=$?

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

# @arg $1 scenario name
# @arg $2 expected-output fixture file (under FIXTURES)
# @arg $@ rest passed verbatim to script
function run_golden_scenario() {
  local -r name="$1"
  local -r expected_file="${FIXTURES}/$2"
  shift 2

  local stdout_file
  stdout_file="$(mktemp)"

  "${SCRIPT}" "$@" >"${stdout_file}"

  if ! diff --unified -- "${expected_file}" "${stdout_file}"; then
    printf 'FAIL: %s — output differs from %s\n' "${name}" "${expected_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${name}"
  fi

  rm --force -- "${stdout_file}"
}

# Failure modes
run_failure_scenario 'no args' 2 'usage' ''
run_failure_scenario 'missing old SBOM' 1 'old SBOM not found' \
  "${FIXTURES}/does-not-exist.json" "${FIXTURES}/new.spdx.json"
run_failure_scenario 'missing new SBOM' 1 'new SBOM not found' \
  "${FIXTURES}/old.spdx.json" "${FIXTURES}/does-not-exist.json"

# Golden outputs
run_golden_scenario 'diff with adds/removes/changes' 'expected-diff.md' \
  "${FIXTURES}/old.spdx.json" "${FIXTURES}/new.spdx.json" 20251101-abcdef0
run_golden_scenario 'identical SBOMs → no-change block' 'expected-nochange.md' \
  "${FIXTURES}/old.spdx.json" "${FIXTURES}/old.spdx.json" 20251101-abcdef0

if ((failures != 0)); then
  printf '%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'all sbom-diff tests passed\n'
