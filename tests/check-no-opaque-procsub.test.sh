#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-no-opaque-procsub.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/no-opaque-procsub"

# @description Run the lint over one fixture dir (or the real scripts/
# tree when the override is empty) and assert the exit code plus every
# expected stderr substring.
# @arg $1 SCRIPTS_DIR_OVERRIDE value  @arg $2 wanted exit code
# @arg $3 scenario label  @arg $@ wanted stderr substrings
function expect() {
  local -r dir_override="$1" want_exit="$2" label="$3"
  shift 3
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
  local want_msg
  for want_msg in "$@"; do
    if [[ ${got_stderr} != *"${want_msg}"* ]]; then
      printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got_stderr}" >&2
      return 1
    fi
  done
  printf 'OK   %s\n' "${label}"
}

readonly PARSER_DIAG='parser process substitution feeds a redirection (yq/jq exit status lost under pipefail)'
readonly FUNC_DIAG='function process substitution feeds a redirection (same-file producer exit status lost under pipefail)'

expect "${FIXTURES}/bad" 1 "bad-yq" "${PARSER_DIAG}" "done < <(yq eval"
expect "${FIXTURES}/bad-jq" 1 "bad-jq" "${PARSER_DIAG}" "done < <(jq --raw-output"
expect "${FIXTURES}/bad-func" 1 "bad-func" "${FUNC_DIAG}" "done < <(collect_files"
expect "${FIXTURES}/good" 0 "good"
# `diff` takes both substitutions as file arguments and its own status is
# what the caller acts on, so a function-fed pair here is not a hit.
expect "${FIXTURES}/good-diff" 0 "good-diff"
expect "" 0 "real scripts/"

printf 'all tests passed\n'
