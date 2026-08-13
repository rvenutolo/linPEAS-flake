#!/usr/bin/env bash
# The banned commands named in prose and in a label string, with no
# producer call anywhere: find and git ls-files appear only as text.
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function listed_sources() {
  printf '%s\0' 'README.md'
}

paths=()
enumerate_into paths 'git ls-files' listed_sources
printf '%s\n' "${paths[@]}"
