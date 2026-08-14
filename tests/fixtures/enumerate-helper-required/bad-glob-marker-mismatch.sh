#!/usr/bin/env bash
# The sibling marker names a different rule. A rationale for running a
# producer outside the enumeration helper says nothing about whether this
# loop's match set is allowed to come back empty.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
# enumerate-exempt: output feeds diff as a file operand, so diff's own
# status is what the caller acts on
for f in ./*.yml; do
  printf '%s\n' "${f}"
done
