# tests/fixtures/refresh-scripts-reference/library.sh
#
# @description A library fixture exercising library-scope parsing.
# Second header line.
# shellcheck shell=bash

# @description First function, with two args on one line and a stdout.
# @arg $1 alpha  @arg $2 beta
# @stdout the joined pair
# shellcheck disable=SC2120 # directive between block and function
function first() {
  printf '%s %s\n' "$1" "$2"
}

# @description Second function, declared without the keyword.
# @exitcode 0 on success
# @exitcode 2 when the input is missing
second() {
  [[ -n ${1:-} ]] || return 2
}

# A plain comment run with no tag must not open a block.
export LIBRARY_FIXTURE_LOADED=1
