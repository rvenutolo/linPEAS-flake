#!/usr/bin/env bash
# A pattern written literally inside an expansion word at a loop head.
# The metacharacter sits one level in — the alternate word of an
# expansion rather than the loop word itself — but it is expanded right
# here, and under nullglob a root holding nothing leaves the body unrun,
# which is the clean line a healthy tree prints.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
for f in ${SCAN_ROOT+*.yml}; do
  printf '%s\n' "${f}"
done
shopt -u nullglob
