#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

hits="$(yq eval '.x' "$f")"
while IFS= read -r f; do
  echo "${f}"
done <<<"${hits}"
