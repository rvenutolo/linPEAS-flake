#!/usr/bin/env bash
# Every pattern here reaches the helper as a call argument and never as a
# loop item, which is the structural reason a compliant call site cannot
# be read as the shape this rule bans.
set -Eeuo pipefail
IFS=$'\n\t'

docs=()
glob_into docs 'markdown' "${PWD}/*.md"
sources=()
glob_into sources 'shell' "${PWD}/*.sh"
printf '%s\n' "${docs[@]}" "${sources[@]}"
