#!/usr/bin/env bash
# The filter value copied to a name the predicate does not match. The copy
# is the violation wherever it is later read: a name-keyed rule cannot see
# the read, and one pass cannot trace the value to it.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

want="${FILE_FILTER}"
for p in "${selected[@]}"; do
  [[ ${p##*/} == "${want}" ]] || continue
  printf '%s\n' "${p}"
done
