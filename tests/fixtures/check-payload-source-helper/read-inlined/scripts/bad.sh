#!/usr/bin/env bash
# Fixture: the banned shape for the read invariant. The payload is
# captured with a hand-rolled `cat --` read instead of the library
# helper, and the captured variable is gated the way a real payload
# read would be.
set -Eeuo pipefail
IFS=$'\n\t'

readonly payload_path
payload_json="$(cat -- "${payload_path}")"
require_json_payload 'renovate.json' "${payload_json}"
printf '%s\n' "${payload_json}"
