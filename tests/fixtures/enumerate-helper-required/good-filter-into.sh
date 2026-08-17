#!/usr/bin/env bash
# The compliant shape: the filter value is read once, at file scope, and
# handed straight to the helper that asserts the selection is not empty.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
printf '%s\n' "${selected[@]}"
