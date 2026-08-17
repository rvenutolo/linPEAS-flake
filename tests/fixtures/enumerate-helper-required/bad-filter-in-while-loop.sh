#!/usr/bin/env bash
# The rule is not for-only: a while loop reading the filter variable in its
# body throws away the same breadth guarantee.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
while read -r f; do
  if [[ ${f##*/} == "${FILE_FILTER}" ]]; then
    printf '%s\n' "${f}"
  fi
done <<<"${selected[*]}"
