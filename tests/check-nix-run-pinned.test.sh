#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-nix-run-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/nix-run-pinned"

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

expect good-shell.sh 0 ""
expect good-pinned-rev.sh 0 ""
expect good-local-flake.sh 0 ""
expect good-prose.md 0 ""
expect bad-unpinned.sh 1 "unpinned"
expect bad-fence.md 1 "unpinned"
expect bad-fence-unlabeled.md 1 "unpinned"
expect bad-run-flag.sh 1 "nix run --quiet nixpkgs#cosign -- version"
expect bad-shell-unpinned.sh 1 "nix shell nixpkgs#cosign --command cosign version"
expect bad-develop-unpinned.sh 1 "nix develop nixpkgs#foo"
expect bad-build-unpinned.sh 1 "nix build nixpkgs#bar"
expect bad-trailing-ref.sh 1 "nix shell .#jq nixpkgs#cosign --command cosign version"

printf 'all tests passed\n'
