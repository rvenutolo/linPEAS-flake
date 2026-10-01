#!/usr/bin/env bash
# The call may follow another command inside the substitution.
set -Eeuo pipefail
IFS=$'\n\t'

function main() {
  # shellcheck disable=SC2155 # the masked status is the shape under test
  local r="$(cd sub && repo_toplevel)"
  printf 'root at %s\n' "${r}"
}
main "$@"
