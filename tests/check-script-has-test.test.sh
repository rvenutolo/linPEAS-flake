#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-script-has-test.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/script-has-test"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  # Each fixture populates only the side its scenario is about, so the
  # other scan root is deliberately empty here. The breadth assertion both
  # roots carry against the real tree is held by
  # tests/glob-scan-breadth.test.sh, which points each one at an empty
  # directory on purpose.
  got_stderr="$(LINT_ALLOW_EMPTY_SCAN=1 \
    SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture}/scripts" \
    TESTS_DIR_OVERRIDE="${FIXTURES}/${fixture}/tests" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good 0 ""
expect good-exempt 0 ""
expect bad-missing-test 1 "missing matching test"
expect bad-orphan-test 1 "missing matching script"

printf 'all tests passed\n'
