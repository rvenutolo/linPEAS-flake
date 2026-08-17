#!/usr/bin/env bash
# A producer named inside the label the helper prints. The word is data a
# diagnostic quotes, not a command the file runs, and every compliant call
# site in this repo passes one.
set -Eeuo pipefail
IFS=$'\n\t'

declare -a paths=()
enumerate_into paths 'git ls-files' git ls-files -z -- 'scripts/*.sh'
printf '%s\n' "${#paths[@]}"
