#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-script-shebang-pipefail.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/script-shebang-pipefail"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(SCRIPTS_DIR_OVERRIDE="${FIXTURES}" \
    SCRIPT_FILE_FILTER="${fixture}" \
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

expect good.sh 0 ""
expect good-with-flags.sh 0 ""
expect bad-shebang.sh 1 "first line"
expect bad-no-pipefail.sh 1 "missing"
expect bad-weak-set.sh 1 "missing"
# The library half of the rule. Each violation names which half it broke,
# so no two of these three collapse onto one message.
expect good-lib.sh 0 ""
expect bad-lib-shebang.sh 1 "opens with a shebang"
expect bad-lib-sets-options.sh 1 "sets its own shell options"
expect bad-lib-no-directive.sh 1 "carries no shellcheck shell= directive"
expect no-such-script.sh 2 'selected 0 of'

printf 'all tests passed\n'
