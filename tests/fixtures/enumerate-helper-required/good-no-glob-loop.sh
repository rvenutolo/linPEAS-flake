#!/usr/bin/env bash
# A loop over an already-populated array carries no pattern at all, so
# there is no match set here whose size could go unasserted.
set -Eeuo pipefail
IFS=$'\n\t'

items=('one' 'two')
for item in "${items[@]}"; do
  printf '%s\n' "${item}"
done
