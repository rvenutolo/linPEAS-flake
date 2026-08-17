#!/usr/bin/env bash
# A loop calling a function that reads no filter. The hop widens where a
# filter read counts as an in-loop read; it does not make a called function
# a finding on its own.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

function shout() {
  printf '%s\n' "${1^^}"
}

for p in "${selected[@]}"; do
  shout "${p}"
done
