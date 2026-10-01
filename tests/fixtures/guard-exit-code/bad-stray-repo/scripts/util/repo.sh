#!/usr/bin/env bash
# A namesake of the helper outside lib/ is an ordinary script.
set -Eeuo pipefail
IFS=$'\n\t'

top="$(git rev-parse --show-toplevel)"
printf 'root at %s\n' "${top}"
