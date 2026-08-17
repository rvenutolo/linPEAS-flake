#!/usr/bin/env bash
# The sibling marker names a different rule. A rationale for a glob's
# empty match being expected says nothing about a loop reading a filter
# variable the helper already selected.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
for f in "${selected[@]}"; do
  # glob-exempt: a leftover scratch file is normally absent, so an empty
  # match is that loop's expected state
  if [[ ${f##*/} == "${FILE_FILTER}" ]]; then
    printf '%s\n' "${f}"
  fi
done
