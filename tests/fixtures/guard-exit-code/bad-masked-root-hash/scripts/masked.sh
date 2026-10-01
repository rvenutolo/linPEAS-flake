#!/usr/bin/env bash
# A ${v#p} expansion ahead of the call does not end the declaration.
set -Eeuo pipefail
IFS=$'\n\t'

function main() {
  local -r q="./x"
  # shellcheck disable=SC2155 # the masked status is the shape under test
  local p="${q#./}" r="$(repo_toplevel)"
  printf '%s at %s\n' "${p}" "${r}"
}
main "$@"
