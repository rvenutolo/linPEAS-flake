#!/usr/bin/env bash
# The same literal pattern one level inside an expansion, in an array
# element rather than at a loop head. The array comes back empty from a
# root holding nothing and the run exits clean.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
# shellcheck disable=SC2206 # the unquoted expansion is the shape this fixture exercises
found=(${SCAN_ROOT:-*.yaml})
shopt -u nullglob
printf '%s\n' "${#found[@]}"
