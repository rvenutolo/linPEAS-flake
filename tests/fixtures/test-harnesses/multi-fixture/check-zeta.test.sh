#!/usr/bin/env bash
# tests/fixtures/test-harnesses/multi-fixture/check-zeta.test.sh
#
# Census fixture: one harness reaching three fixture directories through
# three path literals, so the census renders them de-duplicated and sorted
# in a single cell. The census reads this file as text; it is never
# executed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT="${REPO_ROOT}/scripts/check-zeta.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/zeta"
readonly EXTRA="${REPO_ROOT}/tests/fixtures/zeta-extra"
readonly MORE="${REPO_ROOT}/tests/fixtures/zeta-more"

printf '%s %s %s %s\n' "${SCRIPT}" "${MORE}" "${FIXTURES}" "${EXTRA}"
