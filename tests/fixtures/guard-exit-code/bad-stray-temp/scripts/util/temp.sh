#!/usr/bin/env bash
# A second file named temp.sh, sitting outside lib/. The sanctioned bare
# invocation belongs to the one helper at lib/temp.sh; a namesake
# elsewhere is an ordinary script and its bare mktemp is a violation.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(mktemp)"
trap 'rm --force -- "${tmp}"' EXIT

printf 'scratch at %s\n' "${tmp}"
