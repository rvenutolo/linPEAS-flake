#!/usr/bin/env bash
# tests/check-run-block-pyflakes-required.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-run-block-pyflakes-required.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-run-block-pyflakes-required"

failures=0

# @description Render the scope summary the guard prints on stdout, so a
# scenario states the breadth it expects the run to have covered rather
# than repeating the format string once per scenario.
# @arg $1 workflow files scanned  @arg $2 run: blocks seen
# @arg $3 python invocations found
function summary() {
  printf 'run-block-pyflakes: scanned %d workflow file(s), %d run: block(s); %d python invocation(s)' \
    "$1" "$2" "$3"
}

# @description Run the guard over a scan root and assert its exit code, a
# stderr substring, and the scope summary it prints on stdout.
# @arg $1 scenario name
# @arg $2 scan root handed to the guard
# @arg $3 expected exit code
# @arg $4 expected stderr substring (empty string skips the check)
# @arg $5 expected stdout substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r scan_root="$2"
  local -r expected_exit="$3"
  local -r expected_stderr_substr="$4"
  local -r expected_stdout_substr="${5:-}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  PYFLAKES_GUARD_SCAN_ROOT_OVERRIDE="${scan_root}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr_substr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout_substr} ]]; then
    harness_assert_also "${expected_stdout_substr}"
  fi

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr_substr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr_substr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr_substr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout_substr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout_substr}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout_substr}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm -f -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

clean_only="$(mktemp -d)"
cp -- "${FIXTURES}/clean.yml" "${clean_only}/clean.yml"
run_scenario "no python run: → passes" "${clean_only}" 0 "" \
  "$(summary 1 2 0)"

with_python="$(mktemp -d)"
cp -- "${FIXTURES}/clean.yml" "${with_python}/clean.yml"
cp -- "${FIXTURES}/python-run.yml" "${with_python}/python-run.yml"
run_scenario "python run: present → fails with runbook pointer" \
  "${with_python}" 1 "docs/actionlint-embedded-linters.md" \
  "$(summary 2 3 1)"

with_inline_python="$(mktemp -d)"
cp -- "${FIXTURES}/clean.yml" "${with_inline_python}/clean.yml"
cp -- "${FIXTURES}/inline-python-run.yml" "${with_inline_python}/inline-python-run.yml"
run_scenario "inline python run: present → fails with runbook pointer" \
  "${with_inline_python}" 1 "docs/actionlint-embedded-linters.md" \
  "$(summary 2 7 5)"

# The scan root holds one file with a single non-python run: block, so the
# summary separates it from the clean scenario above by the breadth it
# covered rather than by the fixture it was handed.
clean_with_python_keys="$(mktemp -d)"
cp -- "${FIXTURES}/clean-with-python-keys.yml" \
  "${clean_with_python_keys}/clean-with-python-keys.yml"
run_scenario "setup-python action + python-version keys → passes" \
  "${clean_with_python_keys}" 0 "" \
  "$(summary 1 1 0)"

# A scan root that is not there makes `find` exit 1 having printed nothing,
# which the breadth line would otherwise report as `scanned 0 workflow
# file(s)` at exit 0 — a count of what was read, standing in for a verdict.
run_scenario "missing scan root is a could-not-run" \
  "${clean_only}/absent" 2 "find failed enumerating" ""

# An existing scan root holding no YAML reaches the same zero breadth by a
# different route, so it gets its own diagnostic rather than sharing one.
empty_root="$(mktemp -d)"
run_scenario "empty scan root is a could-not-run" \
  "${empty_root}" 2 "enumerated 0 workflow file(s)" ""

rm -rf -- "${clean_only}" "${with_python}" \
  "${with_inline_python}" "${clean_with_python_keys}" "${empty_root}"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi
printf '\nAll scenarios passed.\n'
