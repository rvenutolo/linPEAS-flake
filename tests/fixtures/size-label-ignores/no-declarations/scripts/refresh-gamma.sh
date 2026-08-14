#!/usr/bin/env bash
# tests/fixtures/size-label-ignores/no-declarations/scripts/refresh-gamma.sh
#
# @description Fixture generator that declares nothing, so a scan root
# holding only this script reads zero declarations.

set -Eeuo pipefail
IFS=$'\n\t'

printf 'gamma\n'
