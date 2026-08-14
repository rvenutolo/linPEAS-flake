#!/usr/bin/env bash
# A scan loop iterating a glob at the loop head. An overridable root that
# exists and holds nothing expands to nothing, the body never runs, and
# the run prints the same clean line a healthy tree prints.
set -Eeuo pipefail
IFS=$'\n\t'

DIR="${WORKFLOWS_DIR:-.github/workflows}"
shopt -s nullglob
for f in "${DIR}"/*.yml; do
  printf '%s\n' "${f}"
done
