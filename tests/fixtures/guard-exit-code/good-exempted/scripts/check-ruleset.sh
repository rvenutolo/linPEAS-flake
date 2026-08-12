#!/usr/bin/env bash
# The mirrored ruleset going missing is the drift this check exists to
# report, so the guard keeps exit 1 behind a rationale-bearing marker.
set -Eeuo pipefail
IFS=$'\n\t'

readonly mirror='.github/ruleset-mirror.json'

if [[ ! -f ${mirror} ]]; then
  printf 'no live ruleset mirrored at %s\n' "${mirror}" >&2
  exit 1 # exit-code-exempt: absence of a live ruleset is the finding
fi

printf 'ok\n'
