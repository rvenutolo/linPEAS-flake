#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# The producer is an ordinary command, neither a parser nor a function
# this file defines: the ban is on the shape, not on what fills it.
while IFS= read -r f; do
  echo "${f}"
done < <(find . -name '*.sh')
