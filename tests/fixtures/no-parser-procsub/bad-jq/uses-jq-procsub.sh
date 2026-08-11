#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

while IFS= read -r f; do
  echo "${f}"
done < <(jq --raw-output 'keys[]' "$f")
