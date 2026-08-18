#!/usr/bin/env bash
# A pattern copied into a variable and expanded unquoted at a loop head.
# The metacharacter is written at the assignment but expanded here, where
# nothing asserts what it matched: under nullglob a root that exists and
# holds nothing leaves the body unrun, and the run prints the clean line
# a healthy tree prints.
set -Eeuo pipefail
IFS=$'\n\t'

pat='scripts/*.sh'
shopt -s nullglob
for f in ${pat}; do
  printf '%s\n' "${f}"
done
shopt -u nullglob
