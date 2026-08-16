#!/usr/bin/env bash
# Fixture: the banned shape under a marker with no rationale. An
# exemption nobody has to justify is a way to switch the rule off, so
# the empty marker excuses nothing and the read is still reported.
set -Eeuo pipefail
IFS=$'\n\t'

readonly payload_path
# payload-read-exempt:
unmarked_json="$(cat -- "${payload_path}")"
printf '%s\n' "${unmarked_json}"
