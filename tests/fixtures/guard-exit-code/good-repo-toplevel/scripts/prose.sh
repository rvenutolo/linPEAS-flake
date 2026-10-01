#!/usr/bin/env bash
# Names git rev-parse --show-toplevel in a whole-line comment, a
# parenthetical, a string operand and a trailing comment, none of which
# runs it.
set -Eeuo pipefail
IFS=$'\n\t'

printf 'resolve the root (git rev-parse --show-toplevel) first\n'
printf 'or run git rev-parse --show-toplevel by hand\n' # see git rev-parse --show-toplevel
