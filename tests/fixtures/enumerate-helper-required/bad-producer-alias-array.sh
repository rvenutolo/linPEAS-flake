#!/usr/bin/env bash
# The same copy written as a command array. The producer word is an
# element rather than a whole value, so a rule reading only scalar
# assignments misses it.
set -Eeuo pipefail
IFS=$'\n\t'

declare -a lister=(git ls-files -z)
"${lister[@]}" -- 'scripts/*.sh'
