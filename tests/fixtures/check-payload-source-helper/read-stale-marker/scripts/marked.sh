#!/usr/bin/env bash
# Fixture: a marker on a file that holds no hand-rolled read at all. The
# file already reads through the library helper, so the marker excuses
# nothing and is drift.
set -Eeuo pipefail
IFS=$'\n\t'

readonly payload_path
# payload-read-exempt: nothing here matches the rule
read_json_payload_into payload_json "${payload_path}" 'renovate.json'
readonly payload_json
printf '%s\n' "${payload_json}"
