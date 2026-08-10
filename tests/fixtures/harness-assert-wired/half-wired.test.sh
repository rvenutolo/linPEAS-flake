#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/half-wired.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness that greps a
# captured output stream and sources the gate library but never runs the
# verification step, so nothing is ever checked. The wiring meta-harness
# reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'expected token' "${stderr_file}"
  harness_assert_record 'scenario' 'expected token' "${stderr_file}"
}

function main() {
  run_scenario
}

main "$@"
