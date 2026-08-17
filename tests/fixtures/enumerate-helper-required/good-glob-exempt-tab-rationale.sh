#!/usr/bin/env bash
# A sanctioned exception whose rationale carries a literal tab right
# after the marker word: the comment record this lint emits is a
# TAB-separated field, and this rationale is the last field on its
# line, so bash `read` hands the whole remainder — tab included — to
# the variable that reads it. The exemption has to be honored exactly
# as it would be with an ordinary space there.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
# glob-exempt:	a leftover scratch file is normally absent, so an empty match is this loop's expected state
for stray in ./.probe-scratch-*.md; do
  rm --force -- "${stray}"
done
