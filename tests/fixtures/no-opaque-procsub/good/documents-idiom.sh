#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Capture jq's output rather than feeding the loop from a process
# substitution: writing this as done < <(jq --raw-output 'keys[]' "$f")
# would lose jq's exit status under pipefail. The yq form
# done < <(yq eval '.x' "$f") loses it the same way.
f="$1"
keys="$(jq --raw-output 'keys[]' "$f")"
while IFS= read -r k; do
  echo "${k}"
done <<<"${keys}"
