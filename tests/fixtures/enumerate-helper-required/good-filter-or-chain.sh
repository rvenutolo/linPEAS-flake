#!/usr/bin/env bash
# A `||` chain onto a loop is the same guard shape with the opposite
# sense: the loop runs only when the read in the condition comes back
# false, and that read is still made and consumed before the loop
# starts, so it stays a file-scope read rather than a loop read.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
[[ -z ${FILE_FILTER} ]] || for f in "${selected[@]}"; do
  printf '%s\n' "${f}"
done
