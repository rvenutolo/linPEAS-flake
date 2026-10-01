#!/usr/bin/env bash
# A marker with no rationale excuses nothing.
set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck disable=SC2016 # the literal is the text to compare against, never run
readonly WANT='$(git rev-parse --show-toplevel)' # exit-code-exempt:
printf 'want %s\n' "${WANT}"
