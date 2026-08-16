#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/verify-only/verify-only.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness that greps a
# captured output stream and calls the gate's verification step without
# ever sourcing the gate library, so the call resolves to nothing at run
# time. The meta-harness reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'expected token' "${stderr_file}"
  harness_assert_record 'scenario' 'expected token' "${stderr_file}"
}

function main() {
  run_scenario
  harness_assert_verify
}

main "$@"
