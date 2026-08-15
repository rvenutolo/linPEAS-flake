#!/usr/bin/env bash
# Fixture: the banned shape inside a harness. A harness names the source
# it expects a script to report, so the same hand-written copy lands here.
set -Eeuo pipefail
IFS=$'\n\t'

harness_source='RENOVATE_JSON_OVERRIDE'
printf '%s\n' "${harness_source}"
