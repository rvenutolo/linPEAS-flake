#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

function collect_files() {
  find . -name '*.sh'
}

while IFS= read -r f; do
  echo "${f}"
done < <(collect_files)
