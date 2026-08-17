#!/usr/bin/env bash
# A sanctioned exception: the array collects leftovers whose absence is
# the healthy case, so an empty match set is what this root normally
# looks like rather than a scan that failed to reach anything.
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob
# glob-exempt: a leftover scratch file is normally absent, so an empty
# match is this array's expected state
strays=(./.probe-scratch-*.md)
shopt -u nullglob
rm --force -- "${strays[@]}"
