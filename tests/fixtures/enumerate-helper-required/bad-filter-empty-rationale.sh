#!/usr/bin/env bash
# A filter marker with nothing after the colon is drift, not an exemption:
# honoring it would make the marker a way to opt out of stating a reason.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
for f in "${selected[@]}"; do
  # filter-exempt:
  if [[ ${f##*/} == "${FILE_FILTER}" ]]; then
    printf '%s\n' "${f}"
  fi
done
