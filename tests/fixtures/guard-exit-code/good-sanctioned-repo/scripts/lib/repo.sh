#!/usr/bin/env bash
# The guarded helper keeps the one sanctioned lookup.
set -Eeuo pipefail
IFS=$'\n\t'

function repo_toplevel() {
  local top
  if ! top="$(git rev-parse --show-toplevel)"; then
    exit 2
  fi
  printf '%s\n' "${top}"
}
