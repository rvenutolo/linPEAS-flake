#!/usr/bin/env bash
# filter_into is called from inside a loop body. The loop's own extent
# holds no other *_FILTER read: the call's filter-value argument is the
# only one there, and the filter rule excludes a call's own argument from
# counting as a loop read, since the call itself is what asserts the
# selection is non-empty.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
labels=('workflow YAML')
for label in "${labels[@]}"; do
  paths=()
  selected=()
  filter_into selected "${label}" "${FILE_FILTER}" "${paths[@]}"
  printf '%s\n' "${selected[@]}"
done
