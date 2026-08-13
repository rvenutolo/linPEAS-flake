#!/usr/bin/env bash
# A clean executable beside the library below: its guard already reports
# an absent tool as a could-not-run, so a scan that stops at the top
# level reads a file and finds nothing.
set -Eeuo pipefail
IFS=$'\n\t'

if ! command -v jq >/dev/null 2>&1; then
  printf 'jq not found on PATH\n' >&2
  exit 2
fi

printf 'ok\n'
