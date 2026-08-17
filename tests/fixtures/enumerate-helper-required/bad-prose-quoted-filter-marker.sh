#!/usr/bin/env bash
# tests/fixtures/enumerate-helper-required/bad-prose-quoted-filter-marker.sh
#
# An in-loop filter read whose comment block quotes the filter marker
# without opening a comment with it.
set -Eeuo pipefail

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

for p in "${selected[@]}"; do
  # A deliberate in-loop read would need an inline
  # `# filter-exempt: <rationale>` marker, which this loop does not
  # carry.
  [[ -n ${FILE_FILTER} ]] && printf '%s\n' "${p}"
done
