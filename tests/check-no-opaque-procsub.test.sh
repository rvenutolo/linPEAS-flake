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

readonly HIT_DIAG='process substitution feeds a redirection (producer exit status lost to its subshell)'

# One banned scenario is enough: the ban is on the shape, so a fixture per
# producer kind would restate the same outcome. This one uses a producer
# that is neither a parser nor a function the file defines, which is the
# part of the rule a shape-specific ban would miss.
expect "${FIXTURES}/bad" 1 "banned-procsub" "${HIT_DIAG}" "done < <(find"
# The capture idiom, alongside a comment that spells the banned form out:
# only live code is a hit.
expect "${FIXTURES}/good" 0 "good"
# `diff` takes both substitutions as file arguments and its own status is
# what the caller acts on, so a pair fed to it is not a hit.
expect "${FIXTURES}/good-diff" 0 "good-diff"
expect "" 0 "real scripts/"

printf 'all tests passed\n'
