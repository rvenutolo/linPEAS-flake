#!/usr/bin/env bash
# An option takes its value through a required-parameter expansion, so an
# incomplete command line ends the run with the status reserved for a
# violation the check actually found.
set -Eeuo pipefail
IFS=$'\n\t'

target="${1:?--target needs a directory}"

printf 'target %s\n' "${target}"
