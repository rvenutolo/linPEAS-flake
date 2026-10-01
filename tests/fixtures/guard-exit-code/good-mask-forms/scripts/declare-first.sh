#!/usr/bin/env bash
# A declaration that ends before the call keeps its status, on one line
# or two.
set -Eeuo pipefail
IFS=$'\n\t'

function main() {
  local x
  x="$(repo_toplevel)"
  printf 'root at %s\n' "${x}"
}
readonly A=1
B="$(repo_toplevel)"
printf '%s %s\n' "${A}" "${B}"
main "$@"
