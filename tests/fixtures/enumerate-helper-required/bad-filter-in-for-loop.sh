#!/usr/bin/env bash
# filter_into narrows the set once, but the loop still reads the filter
# variable directly instead of trusting the selection the helper made.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
for f in "${selected[@]}"; do
  if [[ ${f##*/} == "${FILE_FILTER}" ]]; then
    printf '%s\n' "${f}"
  fi
done
