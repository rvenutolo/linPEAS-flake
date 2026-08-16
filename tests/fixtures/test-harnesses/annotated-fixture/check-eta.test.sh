#!/usr/bin/env bash
# tests/fixtures/test-harnesses/annotated-fixture/check-eta.test.sh
# @fixtures tests/fixtures/eta
#
# Census fixture: the fixture directory is reached only by pointing an
# override at it, so no path literal in the body names it and the header
# annotation is the only declaration the census can read. The census reads
# this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT="${REPO_ROOT}/scripts/check-eta.sh"

printf '%s\n' "${SCRIPT}"
