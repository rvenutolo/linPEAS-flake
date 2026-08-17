#!/usr/bin/env bash
# The copy every filter site in this repo writes: an override read into a
# filter-named constant. The target is itself a filter name, so the value
# has not left the set of names the rule can see, and nothing is
# laundered.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"
printf '%s\n' "${selected[@]}"
