#!/usr/bin/env bash
# A glob marker with nothing after the colon is drift, not an exemption:
# honoring it would make the marker a way to opt out of stating a reason.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
# glob-exempt:
probes=(./probe-*.txt)
shopt -u nullglob
printf '%s\n' "${probes[@]}"
