#!/usr/bin/env bash
# The same laundering into an array element rather than a loop head. The
# array comes back empty from a root holding nothing, whatever reads it
# walks nothing, and the run exits clean.
set -Eeuo pipefail
IFS=$'\n\t'

pat='scripts/*.sh'
shopt -s nullglob
# shellcheck disable=SC2206 # the unquoted expansion is the shape this fixture exercises
found=(${pat})
shopt -u nullglob
printf '%s\n' "${#found[@]}"
