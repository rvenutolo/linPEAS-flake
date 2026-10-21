#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

printf 'a\n' | grep -qE a
printf 'b\n' | grep -Fq b
printf 'c\n' | LC_ALL=C grep -q c
printf 'd\n' | grep --silent d
