#!/usr/bin/env bash
# The producer inside a function the helper is handed by name. A wrapper
# is what lets a `cd` scope the emitted paths without the producer
# becoming a process substitution.
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function doc_sources() {
  (cd docs && find . -type f -name '*.md' -print0)
}

paths=()
enumerate_into paths 'find docs' doc_sources
printf '%s\n' "${paths[@]}"
