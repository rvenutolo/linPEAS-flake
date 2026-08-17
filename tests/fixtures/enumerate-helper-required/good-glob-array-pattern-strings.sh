#!/usr/bin/env bash
# The quoted-pattern idiom every compliant call site is written in: a
# pattern travels to `glob_into` as a string and is expanded inside the
# helper, where the match set is asserted. A metacharacter inside quotes
# is not a pattern the assignment expands, so nothing here is a scan
# whose breadth went unasserted — and a rule that read these as one would
# make every call site a violation of the rule it satisfies.
set -Eeuo pipefail
IFS=$'\n\t'

d="${SCAN_ROOT:-.}"
patterns=()
patterns+=("${d}/*.yml")
patterns+=("${d}/*.yaml")
literal=("*")
found=()
glob_into found 'workflow files' "${patterns[@]}"
printf '%s\n' "${found[@]}" "${literal[@]}"
