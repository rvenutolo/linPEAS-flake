#!/usr/bin/env bash
# A filter variable named without a prefix. The rule keys on the name, so
# a pattern admitting only a suffixed form leaves the bare word invisible
# even though it reads a filter the same way any suffixed one does.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)

for p in "${paths[@]}"; do
  [[ ${p##*/} == "${FILTER}" ]] || continue
  printf '%s\n' "${p}"
done
