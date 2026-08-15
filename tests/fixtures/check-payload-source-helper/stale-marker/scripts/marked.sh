#!/usr/bin/env bash
# Fixture: a marker on a file that holds nothing the rule matches. The
# file is already compliant, so the marker excuses nothing and is drift.
set -Eeuo pipefail
IFS=$'\n\t'

# payload-source-exempt: nothing here matches the rule
payload_source_into payload_source RENOVATE_JSON_OVERRIDE 'renovate.json'
readonly payload_source
printf '%s\n' "${payload_source}"
