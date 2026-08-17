#!/usr/bin/env bash
# A sanctioned exception: the marker states why this loop is allowed to
# read the filter value directly rather than through filter_into.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
for f in "${selected[@]}"; do
  # filter-exempt: this loop only logs which filter value matched, it does
  # not narrow the scan set filter_into already asserted
  printf 'matched %s via %s\n' "${f}" "${FILE_FILTER}"
done
