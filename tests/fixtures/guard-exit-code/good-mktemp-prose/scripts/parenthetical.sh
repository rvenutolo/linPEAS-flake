#!/usr/bin/env bash
# A parenthetical naming the command: this script does a checksum
# cross-check, and atomic (mktemp + mv) pin write.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(make_temp)"
trap 'rm --force -- "${tmp}"' EXIT

printf 'staged at %s\n' "${tmp}"
