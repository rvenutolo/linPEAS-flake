#!/usr/bin/env bash
# A filter read two function hops from the loop. The rule reaches one hop
# and says so: this file is legal by the rule as written, and the fixture
# pins that boundary so a future reader learns it from a test rather than
# from a surprise.
set -Eeuo pipefail
IFS=$'\n\t'

readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
declare -a paths=(one two)
declare -a selected=()
filter_into selected 'paths' "${FILE_FILTER}" "${paths[@]}"

function inner() {
  [[ -z ${FILE_FILTER} || ${1##*/} == "${FILE_FILTER}" ]]
}

function outer() {
  inner "$1"
}

for p in "${selected[@]}"; do
  outer "${p}" || continue
  printf '%s\n' "${p}"
done
