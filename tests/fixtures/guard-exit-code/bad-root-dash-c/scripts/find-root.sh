#!/usr/bin/env bash
# Resolves the root relative to the script's own directory, still bare.
set -Eeuo pipefail
IFS=$'\n\t'

here="${BASH_SOURCE[0]%/*}"
root="$(git -C "${here}" rev-parse --show-toplevel)"
printf 'root at %s\n' "${root}"
