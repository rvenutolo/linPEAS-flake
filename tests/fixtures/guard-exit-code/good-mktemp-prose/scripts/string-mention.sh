#!/usr/bin/env bash
# A string operand names the command inside the script's own advice.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(make_temp)"
trap 'rm --force -- "${tmp}"' EXIT

printf 'route every mktemp in this tree through the helper\n'
printf 'scratch at %s\n' "${tmp}"
