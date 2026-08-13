#!/usr/bin/env bash
# The marker is present but says nothing, so the bare invocation is
# exempted from review rather than justified to it.
set -Eeuo pipefail
IFS=$'\n\t'

tmp="$(mktemp)" # exit-code-exempt:
trap 'rm --force -- "${tmp}"' EXIT

printf 'scratch at %s\n' "${tmp}"
