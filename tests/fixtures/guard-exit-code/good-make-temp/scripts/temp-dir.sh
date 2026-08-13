#!/usr/bin/env bash
# The directory form: every argument reaches the underlying command
# unchanged, so a scratch directory is the same one call.
set -Eeuo pipefail
IFS=$'\n\t'

work="$(make_temp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

printf 'work dir at %s\n' "${work}"
