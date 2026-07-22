#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-egress-allowlist.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/egress-allowlist"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
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

expect good.yml 0 ""
expect bad-codeql-missing-release-assets.yml 1 "release-assets.githubusercontent.com"
expect bad-trivy-missing-ghcr-fallback.yml 1 "ghcr.io"
expect bad-release-asset-download.yml 1 "release-assets.githubusercontent.com"
expect bad-sign-missing-timestamp.yml 1 "timestamp.sigstore.dev"
expect bad-sigstore-partial-set.yml 1 "incomplete sigstore host set"
expect bad-verify-carries-timestamp.yml 1 "timestamp.sigstore.dev"
expect bad-denylisted-host.yml 1 "cafe.github.com"
expect bad-flakehub-action.yml 1 "flakehub-cache-action"
expect bad-sbom-missing-raw-githubusercontent.yml 1 "raw.githubusercontent.com"
expect bad-gh-release-upload-missing-uploads.yml 1 "uploads.github.com"
expect bad-verify-missing-tuf.yml 1 "verification requires at least tuf-repo-cdn.sigstore.dev"
expect bad-sbom-missing-get-anchore.yml 1 "get.anchore.io"

printf 'all tests passed\n'
