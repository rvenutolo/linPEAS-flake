#!/usr/bin/env bash
# tests/fixtures/size-label-ignores/scripts/refresh-beta.sh
#
# @description Fixture generator that splices a block into a
# hand-authored file. The annotation sits after a continuation line so
# the parser is exercised on a multi-line description.
# @generates-block docs/beta.md

set -Eeuo pipefail
IFS=$'\n\t'

# @generates docs/not-a-header-declaration.md
printf 'beta\n'
