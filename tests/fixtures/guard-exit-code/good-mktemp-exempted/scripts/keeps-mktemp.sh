#!/usr/bin/env bash
# Both creations report their own failure, so each bare invocation
# carries a rationale-bearing marker rather than routing through the
# helper.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(mktemp)"             # exit-code-exempt: an unwritable tmpdir is the finding this probe reports
dir="$(mktemp --directory)" # exit-code-exempt: the caller scores a tmpdir it cannot write as drift
trap 'rm --recursive --force -- "${tmp}" "${dir}"' EXIT

printf 'scratch at %s and %s\n' "${tmp}" "${dir}"
