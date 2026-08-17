#!/usr/bin/env bash
# A producer name sitting at a non-head index of an array never invoked
# as a command. Only index 0 can become the word a later "${arr[@]}"
# runs, so a producer name elsewhere in the list is data — the shape a
# tool inventory takes when it merely names git among unrelated tools.
set -Eeuo pipefail
IFS=$'\n\t'

readonly -a TOOLS=(bash git jq)
for tool in "${TOOLS[@]}"; do
  command -v "${tool}" >/dev/null
done
