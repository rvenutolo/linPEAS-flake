#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/parity-allowlisted/check-freshness-hook-watches-modules.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a fully wired harness
# whose basename is on the reviewed parity allowlist, registering the one
# collapsed pair that list names. The meta-harness counts it rather than
# reporting it. The meta-harness reads this file as text; it is never
# executed.

set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'expected token' "${stderr_file}"
  harness_assert_record 'scenario' 'expected token' "${stderr_file}"
  harness_assert_parity_exempt 'mentioned' 'absent' 'both leave the identical gap'
}

function main() {
  run_scenario
  harness_assert_verify
}

main "$@"
