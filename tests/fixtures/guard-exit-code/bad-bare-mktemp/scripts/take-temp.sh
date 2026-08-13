#!/usr/bin/env bash
# The scratch file is created with a bare mktemp, so an unwritable
# TMPDIR kills the assignment with mktemp's own exit 1 and the caller
# reports a could-not-run with the code reserved for a violation.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(mktemp)"
trap 'rm --force -- "${tmp}"' EXIT

printf 'scratch at %s\n' "${tmp}"
