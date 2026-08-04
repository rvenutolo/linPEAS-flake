#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-gh-attestation-repo.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/gh-attestation-repo"

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

expect good.sh 0 ""
expect good-eq.sh 0 ""
expect good-md-prose.md 0 ""
expect good-md-code.md 0 ""
expect good-md-inline.md 0 ""
expect good-yml-comment.yml 0 ""
expect bad-md-inline.md 1 "missing"
expect bad-yml-inline.yml 1 "missing"
expect bad-missing.sh 1 "missing"
expect bad-wrong-slug.sh 1 "missing"
expect bad-md-code.md 1 "missing"
expect good-chain.sh 0 ""
expect bad-mask-span.md 1 "missing"
expect bad-chain-unquoted.sh 1 "missing"
expect bad-span-chain.md 1 "missing"
expect bad-span-greedy.md 1 "missing"
expect bad-comment-pin.sh 1 "missing"
expect bad-separator-pin.sh 1 "missing"
expect bad-quoted-arg-pin.sh 1 "missing"
expect bad-doubled-space.sh 1 "missing"
expect bad-indented-code.md 1 "missing"
expect bad-tilde-fence.md 1 "missing"
expect bad-attr-info.md 1 "missing"
expect bad-doubled-span.md 1 "missing"
expect bad-nested-span.md 1 "missing"
expect bad-inline-triple.md 1 "missing"
expect bad-multiline-span.md 1 "missing"
expect good-quoted-slug.sh 0 ""
expect good-odd-backtick.md 0 ""

printf 'all tests passed\n'
