#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

while IFS= read -r f; do
  echo "${f}"
done < <(yq eval '.x' "$f")
