#!/usr/bin/env bash
# The guarded helper itself, at the one path the rule sanctions. Its bare
# mktemp is the invocation every other site routes through, so the
# bare-creation rule is switched off here and nowhere else.
set -Eeuo pipefail
IFS=$'\n\t'

function make_temp() {
  local path
  if ! path="$(mktemp "$@")"; then
    printf 'could not create a temp file\n' >&2
    return 2
  fi
  printf '%s\n' "${path}"
}
