#!/usr/bin/env bash
# A second, later read of the same filter value is still file scope, not a
# loop body: this shape is legal by position, not by what the second read
# guards. check-egress-allowlist.sh reads its filter twice this way, once
# to narrow the set and once to guard a job-count assertion; check-
# permission-scopes.sh reads it twice too, but its second read guards a
# reverse allowlist-staleness pass instead.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
job_count=0
if [[ -z ${FILE_FILTER} ]]; then
  job_count=2
fi
printf '%d\n' "${job_count}"
printf '%s\n' "${selected[@]}"
