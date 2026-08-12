#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-manifest-digest-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/manifest-digest-pinned"

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

expect good-digest-literal.yml 0 ""
expect good-digest-var.yml 0 ""
expect good-inspect.yml 0 ""
expect good-manifest-create.yml 0 ""
expect good-manifest-annotate.yml 0 ""
expect good-log-line.yml 0 ""
expect good-prose.md 0 ""
expect bad-mutable-tag.yml 1 "amd64"
expect bad-mixed-continuation.yml 1 "arm64"
expect bad-manifest-create.yml 1 "amd64"
expect bad-manifest-annotate.yml 1 "arm64"
expect bad-nondigest-var.yml 1 "AMD64_REF"
expect bad-fence.md 1 "amd64"

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

expect_empty_scan 2 "enumerated 0 files via git"

printf 'all tests passed\n'
