#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

printf 'a\n' | grep -qE a
printf 'b\n' | grep -Fq b
printf 'c\n' | LC_ALL=C grep -q c
printf 'd\n' | grep --silent d
printf 'e\n' | grep -qm1 e
printf 'f\n' | grep -qA2 f
printf 'g\n' | grep --q g
printf 'h\n' | grep --qui h
printf 'i\n' | grep --quie i
printf 'j\n' | grep --s j
printf 'k\n' | grep --sil k
printf 'l\n' | grep --silen l
