#!/usr/bin/env bash
# Fixture: the banned shape, excused by a marker carrying a rationale.
set -Eeuo pipefail
IFS=$'\n\t'

# payload-source-exempt: names the variable for an operator message, not for a payload gate
label='RENOVATE_JSON_OVERRIDE'
printf 'point this run at a fixture by setting %s\n' "${label}"
