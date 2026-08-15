#!/usr/bin/env bash
# tests/check-lib-source-tool-free.test.sh
#
# Spec-driven harness for scripts/check-lib-source-tool-free.sh. Drives the
# lint against fixture scripts/ roots via SCRIPTS_DIR_OVERRIDE, then
# asserts it holds on the live tree.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-lib-source-tool-free.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/lib-source-tool-free"

failures=0

# ${1}=scenario name  ${2}=scripts root  ${3}=wanted exit
# ${4}=wanted stderr substring ('' for none)
# ${5}=1 to run with LINT_ALLOW_EMPTY_SCAN set (default: unset)
function expect() {
  local -r name="$1" scripts_dir="$2" want_exit="$3" want_msg="$4"
  local -r allow_empty="${5:-}"

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  LINT_ALLOW_EMPTY_SCAN="${allow_empty}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
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
  expect 'readlink resolution is a violation' \
    "${FIXTURES}/readlink/scripts" 1 \
    'uses-readlink.sh'

  expect 'dirname resolution is a violation' \
    "${FIXTURES}/dirname/scripts" 1 \
    'uses-dirname.sh'

  expect 'tool-free resolution is clean' \
    "${FIXTURES}/clean/scripts" 0 ''

  # No .sh file exists under this root at all, so glob_into's own
  # empty-match guard reports the could-not-run before the script's own
  # source-line tally ever runs.
  expect 'empty scan root is a could-not-run' \
    "${FIXTURES}/empty/scripts" 2 'matched 0 files'

  expect 'empty scan root passes when allowed' \
    "${FIXTURES}/empty/scripts" 0 '' 1

  expect 'the live tree is clean' \
    "${REPO_ROOT}/scripts" 0 ''

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
