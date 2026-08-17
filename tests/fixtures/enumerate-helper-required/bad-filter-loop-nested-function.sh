#!/usr/bin/env bash
# A function declared inside a loop body, and called by that same loop,
# has a body whose offset range sits inside both the loop's own extent and
# the one-hop function set the loop reaches. The read stays classified as
# a loop read rather than double-counting as a function read too: the two
# sets are kept apart precisely so an overlapping site is not reported
# twice under two different names.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

for p in "${selected[@]}"; do
  function want() {
    [[ ${1##*/} == "${FILE_FILTER}" ]]
  }
  want "${p}" || continue
  printf '%s\n' "${p}"
done
