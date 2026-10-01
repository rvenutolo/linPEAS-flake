#!/usr/bin/env bash
# local returns its own status, so the 2 is lost.
set -Eeuo pipefail
IFS=$'\n\t'

function main() {
  # shellcheck disable=SC2155 # the masked status is the shape under test
  local root="$(repo_toplevel)"
  printf 'root at %s\n' "${root}"
}
main "$@"
