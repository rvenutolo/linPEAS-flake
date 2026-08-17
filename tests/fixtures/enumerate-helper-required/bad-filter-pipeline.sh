#!/usr/bin/env bash
# An upstream pipeline stage feeding a `while` is also the loop's input,
# not its body: the filter read here happens before the loop ever
# starts, but the loop still consumes whatever the read let through.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
printf '%s\n' "${selected[@]}" | grep -F -- "${FILE_FILTER}" | while IFS= read -r f; do
  printf '%s\n' "${f}"
done
