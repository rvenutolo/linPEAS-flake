#!/usr/bin/env bash
# The filter value is read but never handed to filter_into: nothing here
# asserts that the selection it drives is non-empty.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
printf '%s\n' "${FILE_FILTER}"
