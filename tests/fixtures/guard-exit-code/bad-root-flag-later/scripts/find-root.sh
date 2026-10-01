#!/usr/bin/env bash
# An option before the flag does not hide the lookup.
set -Eeuo pipefail
IFS=$'\n\t'

root="$(git rev-parse --path-format=absolute --show-toplevel)"
printf 'root at %s\n' "${root}"
