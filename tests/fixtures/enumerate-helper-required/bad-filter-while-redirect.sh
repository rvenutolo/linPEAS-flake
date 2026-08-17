#!/usr/bin/env bash
# A while loop's own input is part of what it consumes, exactly as much
# as its body: reading the filter variable in the process-substitution
# redirect feeding `done` re-applies the same test outside filter_into,
# one syntactic step earlier than the body would.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
while IFS= read -r f; do
  printf '%s\n' "${f}"
done < <(printf '%s\n' "${selected[@]}" | grep -F -- "${FILE_FILTER}")
