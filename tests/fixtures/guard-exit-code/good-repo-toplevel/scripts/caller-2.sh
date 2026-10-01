#!/usr/bin/env bash
# Resolves the root through the helper.
set -Eeuo pipefail
IFS=$'\n\t'

function main() {
  local root
  root="$(repo_toplevel)"
  printf 'root at %s\n' "${root}"
}
main "$@"
