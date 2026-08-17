#!/usr/bin/env bash
# The same input-side read, spelled as a herestring instead of a process
# substitution: `done <<<"…"` is as much the loop's input as `done <
# <(…)` is, and a filter read there is just as invisible to a check that
# only looks at the bare loop node.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
while IFS= read -r f; do
  printf '%s\n' "${f}"
done <<<"$(printf '%s\n' "${selected[@]}" | grep -F -- "${FILE_FILTER}")"
