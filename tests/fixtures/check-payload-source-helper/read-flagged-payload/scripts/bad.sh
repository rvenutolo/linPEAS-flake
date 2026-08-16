#!/usr/bin/env bash
# Fixture: the banned shape with an option ahead of the `--` separator.
# The violation report must name the path operand that follows `--`,
# never the separator itself — a report naming `--` tells a maintainer
# nothing about which read to convert.
set -Eeuo pipefail
IFS=$'\n\t'

readonly payload_path
payload_json="$(cat --squeeze-blank -- "${payload_path}")"
printf '%s\n' "${payload_json}"
