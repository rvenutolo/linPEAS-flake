#!/usr/bin/env bash
# tests/fixtures/test-harnesses/both-declared/check-gamma.test.sh
# @subject scripts/lib/gamma.sh
#
# Census fixture: a harness that names a subject twice — once through a
# SCRIPT= assignment pointing into scripts/ and once through a header
# annotation. The two can disagree, so the census refuses to pick one.
# The census reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT="${REPO_ROOT}/scripts/check-gamma.sh"

printf '%s\n' "${SCRIPT}"
