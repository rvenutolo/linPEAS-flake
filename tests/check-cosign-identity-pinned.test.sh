#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-cosign-identity-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/cosign-identity-pinned"

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
expect good-prose.md 0 ""
expect bad-no-identity.sh 1 "certificate-identity"
expect bad-no-issuer.sh 1 "certificate-oidc-issuer"
expect bad-bare.sh 1 "certificate-identity"
expect bad-fence.md 1 "certificate-identity"
expect good-verify-blob.sh 0 ""
expect good-verify-boundary.sh 0 ""
expect good-log-line.sh 0 ""
expect bad-verify-blob.sh 1 "certificate-identity"
expect bad-verify-blob-no-issuer.sh 1 "certificate-oidc-issuer"
expect bad-verify-attestation.sh 1 "certificate-identity"
expect bad-verify-blob-attestation.sh 1 "certificate-identity"
expect bad-verify-blob-fence.md 1 "certificate-identity"

printf 'all tests passed\n'
