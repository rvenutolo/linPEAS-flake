#!/usr/bin/env bash
# A quoted read of a pattern-bearing variable expands nothing: the loop
# iterates one literal string and the array holds one literal element, so
# neither is a scan whose breadth went unasserted. A rule that counted a
# quoted read would make the ordinary way of passing a pattern to
# glob_into a violation of the rule it satisfies.
set -Eeuo pipefail
IFS=$'\n\t'

pat='scripts/*.sh'
found=("${pat}")
matched=()
glob_into matched 'shell sources' "${pat}"
# shellcheck disable=SC2066 # the quoted read running the body once is the shape this fixture exercises
for f in "${pat}"; do
  printf '%s\n' "${f}"
done
printf '%s\n' "${found[@]}" "${matched[@]}"
