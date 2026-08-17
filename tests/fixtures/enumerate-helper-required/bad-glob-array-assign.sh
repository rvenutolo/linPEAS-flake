#!/usr/bin/env bash
# An array filled by expanding a pattern in its own element list. An
# overridable root that exists and holds nothing leaves the array empty,
# whatever reads it walks nothing, and the run prints the same clean line
# a healthy tree prints.
set -Eeuo pipefail
IFS=$'\n\t'

DIR="${WORKFLOWS_DIR:-.github/workflows}"
shopt -s nullglob
files=("${DIR}"/*.yml)
shopt -u nullglob
printf '%s\n' "${files[@]}"
