#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-setup-nix-required.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/setup-nix-required"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good.yml 0 ""
expect bad-direct-install.yml 1 \
  "cachix/install-nix-action@b97f05dcb019ddea06450a50ef6203d2fdc19fee installs Nix outside the composite"
expect bad-missing-token.yml 1 "missing github-token"
expect bad-wrong-token.yml 1 "wrong github-token"
expect bad-malformed.yml 1 "could not evaluate"
expect bad-determinate-installer.yml 1 \
  "DeterminateSystems/nix-installer-action@2f1b1a1c8b4e3d9a7c0e5f6b8d2a4c6e0f1a3b5d installs Nix outside the composite"
expect bad-quick-install.yml 1 \
  "nixbuild/nix-quick-install-action@9d1f2e3a4b5c6d7e8f90a1b2c3d4e5f60718293a installs Nix outside the composite"

printf 'all tests passed\n'
