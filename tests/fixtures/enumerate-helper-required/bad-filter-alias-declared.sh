#!/usr/bin/env bash
# The same copy written as a declaration. `local`, `readonly`, `declare`
# and `export` are filed under a different node than a bare assignment,
# so a walk that reads only bare assignments goes blind on the form a
# copy inside a function actually takes.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

function pick() {
  local want="${FILE_FILTER}"
  [[ ${1##*/} == "${want}" ]]
}

for p in "${selected[@]}"; do
  pick "${p}" || printf '%s\n' "${p}"
done
