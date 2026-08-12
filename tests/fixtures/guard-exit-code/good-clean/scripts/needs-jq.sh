#!/usr/bin/env bash
# A required parser is absent: the check never ran, so it says so.
set -Eeuo pipefail
IFS=$'\n\t'

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq not found on PATH\n' >&2
  exit 2
fi

printf 'ok\n'
