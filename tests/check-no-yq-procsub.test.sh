#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-no-yq-procsub.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/no-yq-procsub"

function expect() {
  local -r dir_override="$1" want_exit="$2" want_msg="$3" label="$4"
  local got_exit=0 got_stderr
  if [[ -n ${dir_override} ]]; then
    got_stderr="$(SCRIPTS_DIR_OVERRIDE="${dir_override}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  else
    got_stderr="$("${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  fi
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${label}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

expect "${FIXTURES}/bad" 1 "process substitution" "bad"
expect "${FIXTURES}/good" 0 "" "good"
expect "" 0 "" "real scripts/"

printf 'all tests passed\n'
