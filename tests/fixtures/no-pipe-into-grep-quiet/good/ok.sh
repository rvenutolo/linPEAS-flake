#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

out="$(printf 'a\n')"
grep --quiet a <<<"${out}"
[[ -n ${out} ]] || grep -q x f
# x | grep -q y
grep -q x f
printf 'b\n' | grep -c x
