#!/usr/bin/env bash
# A site that answers to two positions at once: the default word writes a
# literal pattern, and the name being read is one this file gives a
# pattern of its own. It is one scan whose breadth goes unasserted, so it
# earns one finding and one marker, not two of each — and the marker
# below is what makes that countable, since one site consuming it twice
# would report two exemptions from the one comment.
set -Eeuo pipefail
IFS=$'\n\t'

pat='scripts/*.sh'
shopt -s nullglob
# glob-exempt: a tree may legitimately hold no shell script at all, so an
# empty match is this loop's expected state
for f in ${pat-*.yml}; do
  printf '%s\n' "${f}"
done
shopt -u nullglob
