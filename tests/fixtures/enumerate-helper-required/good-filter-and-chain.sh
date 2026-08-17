#!/usr/bin/env bash
# A `&&` chain onto a loop is the guard of the loop, not its input: the
# read here decides whether the loop runs at all, and that decision is
# made and read before the loop consumes anything, so it stays a
# file-scope read even though the loop sits on the right-hand side of
# the same BinaryCmd.
set -Eeuo pipefail
IFS=$'\n\t'

FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
paths=()
selected=()
filter_into selected 'workflow YAML' "${FILE_FILTER}" "${paths[@]}"
[[ -n ${FILE_FILTER} ]] && for f in "${selected[@]}"; do
  printf '%s\n' "${f}"
done
