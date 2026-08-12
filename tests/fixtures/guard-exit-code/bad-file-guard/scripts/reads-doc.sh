#!/usr/bin/env bash
# The input this check reads is not there at all, so nothing was
# inspected — but the guard reports drift.
set -Eeuo pipefail
IFS=$'\n\t'

readonly doc='docs/example.md'

if [[ ! -f ${doc} ]]; then
  printf 'missing %s\n' "${doc}" >&2
  exit 1
fi

printf 'ok\n'
