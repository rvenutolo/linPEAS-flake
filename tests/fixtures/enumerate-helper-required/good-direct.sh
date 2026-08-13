#!/usr/bin/env bash
# The producer handed straight to the helper, which owns its status and
# its breadth together.
set -Eeuo pipefail
IFS=$'\n\t'

paths=()
enumerate_into paths 'git ls-files' git ls-files -z -- '*.md'
printf '%s\n' "${paths[@]}"
