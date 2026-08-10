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

printf 'all tests passed\n'
