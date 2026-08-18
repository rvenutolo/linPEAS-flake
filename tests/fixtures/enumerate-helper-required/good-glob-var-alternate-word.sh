#!/usr/bin/env bash
# The safe-empty-array read idiom over a name that does hold a pattern.
# Under a plus operator the value of the parameter is never emitted at
# all — only the alternate word is, and that word is quoted — so nothing
# here expands a pattern and no match set goes unasserted.
set -Eeuo pipefail
IFS=$'\n\t'

pats=('*.sh')
matched=()
glob_into matched 'shell sources' "${pats[@]}"
for f in ${pats+"${pats[@]}"}; do
  printf '%s\n' "${f}"
done
printf '%s\n' "${matched[@]}"
