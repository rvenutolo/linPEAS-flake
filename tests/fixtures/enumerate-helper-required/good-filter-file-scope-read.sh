#!/usr/bin/env bash
# A second, later read of the same filter value is still file scope, not a
# loop body: the two live sites in check-egress-allowlist.sh and
# check-permission-scopes.sh both read their filter twice this way, once to
# narrow the set and once to guard a job-count assertion.
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
