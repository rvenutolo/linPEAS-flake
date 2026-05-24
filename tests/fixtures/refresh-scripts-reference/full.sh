#!/usr/bin/env bash
# tests/fixtures/refresh-scripts-reference/full.sh
#
# @description Greet a named entity and demonstrate every supported tag.
# Second line of the description, continued.
# @arg $1 NAME the name to greet
# @option --foo enable the foo behavior
# @example
#   full.sh --foo Alice
#   full.sh Bob

set -Eeuo pipefail
IFS=$'\n\t'

# @description this function-level annotation MUST be ignored by the parser.
function greet() {
  printf 'hello %s\n' "$1"
}

greet "$@"
