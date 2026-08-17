#!/usr/bin/env bash
# A filter read that reaches a loop through a function the loop calls. The
# read sits at file scope by position and re-applies the filter test where
# the loop consumes it, which is the shape the rule exists to catch.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

function want() {
  [[ -z ${FILE_FILTER} || ${1##*/} == "${FILE_FILTER}" ]]
}

for p in "${selected[@]}"; do
  want "${p}" || continue
  printf '%s\n' "${p}"
done
