#!/usr/bin/env bash
# The keying holds in the other direction too: a rationale for a glob
# whose empty match is expected says nothing about a producer that
# enumerates nothing and still exits 0.
set -Eeuo pipefail
IFS=$'\n\t'

# glob-exempt: a leftover scratch file is normally absent, so an empty
# match is that loop's expected state
tracked="$(git ls-files -- '*.md')"
printf '%s\n' "${tracked}"
