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

# A workflow yq cannot parse must fail loud, not empty the scan silently.
expect bad-malformed/ci.yml 1 "could not evaluate"

# @description Drive the enumeration itself, not a fixture: with
# PATHS_OVERRIDE unset the script enumerates via `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output. A status
# check cannot see that, so the empty scan set has to be the assertion.
# @arg $1 expected exit code  @arg $2 expected stderr substring
function expect_empty_scan() {
  local -r want_exit="$1" want_msg="$2"
  local got_exit=0 got_stderr index_dir
  index_dir="$(mktemp --directory)"
  got_stderr="$(cd "${REPO_ROOT}" &&
    GIT_INDEX_FILE="${index_dir}/absent.idx" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${index_dir}"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL empty-scan: exit %s, want %s\n  stderr: %s\n' "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL empty-scan: stderr missing %q\n  got: %s\n' "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   empty-scan\n'
}

expect_empty_scan 2 "enumerated 0 files via git ls-files"

printf 'all tests passed\n'
