#!/usr/bin/env bash
# A trailing comment on a code line names the command beside the call
# that does not use it.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(make_temp)" # a bare mktemp here would exit 1 on an unwritable tmpdir
trap 'rm --force -- "${tmp}"' EXIT

printf 'scratch at %s\n' "${tmp}"
