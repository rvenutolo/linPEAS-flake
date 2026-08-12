#!/usr/bin/env bash
# The marker is present but says nothing, so the guard is exempted from
# review rather than justified to it.
set -Eeuo pipefail
IFS=$'\n\t'

readonly mirror='.github/settings-mirror.json'

if [[ ! -f ${mirror} ]]; then
  printf 'no mirror at %s\n' "${mirror}" >&2
  exit 1 # exit-code-exempt:
fi

printf 'ok\n'
