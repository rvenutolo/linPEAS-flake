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

function run_scenario() {
  local -r name="$1"
  local -r scan_root="$2"
  local -r expected_exit="$3"
  local -r expected_stderr_substr="$4"

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
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm -f -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

clean_only="$(mktemp -d)"
cp -- "${FIXTURES}/clean.yml" "${clean_only}/clean.yml"
run_scenario "no python run: → passes" "${clean_only}" 0 ""

with_python="$(mktemp -d)"
cp -- "${FIXTURES}/clean.yml" "${with_python}/clean.yml"
cp -- "${FIXTURES}/python-run.yml" "${with_python}/python-run.yml"
run_scenario "python run: present → fails with runbook pointer" \
  "${with_python}" 1 "docs/actionlint-embedded-linters.md"

with_inline_python="$(mktemp -d)"
cp -- "${FIXTURES}/clean.yml" "${with_inline_python}/clean.yml"
cp -- "${FIXTURES}/inline-python-run.yml" "${with_inline_python}/inline-python-run.yml"
run_scenario "inline python run: present → fails with runbook pointer" \
  "${with_inline_python}" 1 "docs/actionlint-embedded-linters.md"

clean_with_python_keys="$(mktemp -d)"
cp -- "${FIXTURES}/clean-with-python-keys.yml" \
  "${clean_with_python_keys}/clean-with-python-keys.yml"
run_scenario "setup-python action + python-version keys → passes" \
  "${clean_with_python_keys}" 0 ""

rm -rf -- "${clean_only}" "${with_python}" \
  "${with_inline_python}" "${clean_with_python_keys}"

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -ne 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi
printf '\nAll scenarios passed.\n'
