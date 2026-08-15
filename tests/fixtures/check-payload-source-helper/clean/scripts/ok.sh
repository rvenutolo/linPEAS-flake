#!/usr/bin/env bash
# Fixture: the compliant shape. The payload's source is named by the
# library helper, so no assignment in this file writes an override
# variable's name by hand.
set -Eeuo pipefail
IFS=$'\n\t'

payload_source_into payload_source RENOVATE_JSON_OVERRIDE 'renovate.json'
readonly payload_source
printf '%s\n' "${payload_source}"
