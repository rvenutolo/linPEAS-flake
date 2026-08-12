#!/usr/bin/env bash
# A required parser is absent, which is a could-not-run, but the guard
# reports it with the code reserved for a content violation.
set -Eeuo pipefail
IFS=$'\n\t'

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 1
fi

printf 'ok\n'
