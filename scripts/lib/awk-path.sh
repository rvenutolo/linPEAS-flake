# scripts/lib/awk-path.sh
#
# @description Make a path unambiguous as an `awk` file operand.
# `awk` reads an operand whose text is `name=value` as a variable
# assignment rather than a filename, then finds no file operand, reads
# stdin, and exits 0 having scanned nothing — so a relative path whose
# first component contains `=` scores as an empty file. `--` is no help:
# POSIX makes operand assignment parsing independent of it, and gawk
# treats a `--` placed after the program as a filename.
# Source after `set -Eeuo pipefail`.
# shellcheck shell=bash

# @description Print a path in a form `awk` cannot read as an assignment.
# The prefix is conditional because `./` ahead of an absolute path
# resolves as a relative one.
# @arg $1 path
# @stdout the path, `./`-prefixed when relative
function awk_path() {
  local -r p="$1"
  if [[ ${p} == /* ]]; then
    printf '%s' "${p}"
  else
    printf './%s' "${p}"
  fi
}
