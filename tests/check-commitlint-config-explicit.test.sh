#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-commitlint-config-explicit.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/commitlint-config-explicit"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(PATHS_OVERRIDE="${FIXTURES}/${fixture}" \
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

# Expected substrings avoid backticks on purpose: treefmt rewrites a
# double-quoted string holding them into single quotes, and shellcheck
# then reports SC2016 on the same line. Each substring below is still
# unique to the failure it names.
expect good/ci.yml 0 ""
expect no-with/ci.yml 1 "block; add"
expect no-configfile/ci.yml 1 "no non-empty"
expect missing-path/ci.yml 1 "does not exist"
expect extra-rule/ci.yml 1 "rules must be exactly"
expect extends-mismatch/ci.yml 1 "declare different"

printf 'all tests passed\n'
