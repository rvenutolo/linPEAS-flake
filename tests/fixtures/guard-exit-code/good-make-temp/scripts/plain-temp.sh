#!/usr/bin/env bash
# The plain form: the helper reports a failed creation as exit 2 from
# inside the command substitution, so the assignment needs no guard.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(make_temp)"
trap 'rm --force -- "${tmp}"' EXIT

printf 'scratch at %s\n' "${tmp}"
