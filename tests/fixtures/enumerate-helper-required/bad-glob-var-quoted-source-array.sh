#!/usr/bin/env bash
# The source is an array element holding a quoted pattern, which the
# array-assignment position does not classify — a quoted metacharacter is
# not a pattern the assignment expands. The unquoted read is what expands
# it, so the breadth question lands here and is answered nowhere.
set -Eeuo pipefail
IFS=$'\n\t'

pats=('*.sh')
shopt -s nullglob
# shellcheck disable=SC2068 # the unquoted array expansion is the shape this fixture exercises
for f in ${pats[@]}; do
  printf '%s\n' "${f}"
done
shopt -u nullglob
