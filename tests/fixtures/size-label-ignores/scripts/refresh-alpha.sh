#!/usr/bin/env bash
# tests/fixtures/size-label-ignores/scripts/refresh-alpha.sh
#
# @description Fixture generator that owns a whole file.
# @generates docs/alpha.md

set -Eeuo pipefail
IFS=$'\n\t'

printf 'alpha\n'
