#!/usr/bin/env bash
# Fixture: the banned shape, written with a single-quoted literal. The
# override variable's name is assigned by hand instead of being filled by
# the library helper.
set -Eeuo pipefail
IFS=$'\n\t'

if [[ -n ${RENOVATE_JSON_OVERRIDE:-} ]]; then
  payload_source='RENOVATE_JSON_OVERRIDE'
else
  payload_source='renovate.json'
fi
printf '%s\n' "${payload_source}"
