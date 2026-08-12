#!/usr/bin/env bash
# The input is missing and the brace-group form of the guard says so
# with the code that means the check could not run.
set -Eeuo pipefail
IFS=$'\n\t'

readonly manifest='.github/lint-groups.yml'

[[ -f ${manifest} ]] || {
  printf 'missing %s\n' "${manifest}" >&2
  exit 2
}

printf 'ok\n'
