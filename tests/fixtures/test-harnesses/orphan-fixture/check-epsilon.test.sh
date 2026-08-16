#!/usr/bin/env bash
# tests/fixtures/test-harnesses/orphan-fixture/check-epsilon.test.sh
#
# Census fixture: the only harness in a scan root whose fixture tree holds
# a second directory nothing names, so the census has an orphan to report.
# The census reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT="${REPO_ROOT}/scripts/check-epsilon.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/epsilon"

printf '%s %s\n' "${SCRIPT}" "${FIXTURES}"
