#!/usr/bin/env bash
# Fixture: the compliant shape for the read invariant. The payload is
# read through the library helper, so no `cat --` capture appears in
# this file for the rule to examine.
set -Eeuo pipefail
IFS=$'\n\t'

readonly payload_path
read_json_payload_into payload_json "${payload_path}" 'renovate.json'
readonly payload_json
printf '%s\n' "${payload_json}"
