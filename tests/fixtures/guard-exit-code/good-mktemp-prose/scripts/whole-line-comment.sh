#!/usr/bin/env bash
# A whole-line comment naming the command: the mktemp call is guarded,
# so the prose describes the helper rather than invoking anything.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(make_temp)"
trap 'rm --force -- "${tmp}"' EXIT

printf 'scratch at %s\n' "${tmp}"
