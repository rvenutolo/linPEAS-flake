#!/usr/bin/env bash
# The scan routed through the helper, which owns the match set and its
# cardinality together. The loop then walks an ordinary array.
set -Eeuo pipefail
IFS=$'\n\t'

DIR="${WORKFLOWS_DIR:-.github/workflows}"
files=()
glob_into files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
for f in "${files[@]}"; do
  printf '%s\n' "${f}"
done
