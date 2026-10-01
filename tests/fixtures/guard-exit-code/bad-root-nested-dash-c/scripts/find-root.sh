#!/usr/bin/env bash
# A substitution inside the -C argument does not hide the lookup.
set -Eeuo pipefail
IFS=$'\n\t'

root="$(git -C "$(dirname -- "$0")" rev-parse --show-toplevel)"
printf 'root at %s\n' "${root}"
