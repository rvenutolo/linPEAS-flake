#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-harness-preamble.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/harness-preamble"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(TESTS_DIR_OVERRIDE="${FIXTURES}" \
    TEST_FILE_FILTER="${fixture}" \
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

# Both documented REPO_ROOT spellings pass; each preamble element that
# is missing or malformed fails with its own message.
expect good.test.sh 0 ""
expect good-two-step.test.sh 0 ""
expect bad-shebang.test.sh 1 "first line"
expect bad-no-set.test.sh 1 "need it as its own line"
expect bad-no-ifs.test.sh 1 "field-separator"
expect bad-no-readonly.test.sh 1 "never made readonly"
expect bad-no-derive.test.sh 1 "not derived from"
expect no-such-harness.test.sh 2 'selected 0 of'

# Real-tree guard: every live harness carries the documented preamble.
real_exit=0
"${SCRIPT}" >/dev/null 2>&1 || real_exit=$?
if [[ ${real_exit} != 0 ]]; then
  printf 'FAIL real-tree: tests/*.test.sh preamble check exit %s, want 0\n' "${real_exit}" >&2
  exit 1
fi
printf 'OK   real-tree\n'

printf 'all tests passed\n'
