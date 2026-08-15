#!/usr/bin/env bash
# Fixture: a compliant file that also holds an empty single-quoted
# assignment. The parser emits no literal text at all for that word, so a
# detector reading the text unguarded dies on this file rather than on
# anything it is looking for.
set -Eeuo pipefail
IFS=$'\n\t'

live=''
payload_source_into live RENOVATE_JSON_OVERRIDE 'renovate.json'
readonly live
printf '%s\n' "${live}"
