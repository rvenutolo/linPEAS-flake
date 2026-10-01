#!/usr/bin/env bash
# A literal naming the lookup carries a rationale-bearing marker.
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2016 # the literal is the text to compare against, never run
readonly WANT='$(git rev-parse --show-toplevel)' # exit-code-exempt: a literal naming the lookup, never run
printf 'want %s\n' "${WANT}"
