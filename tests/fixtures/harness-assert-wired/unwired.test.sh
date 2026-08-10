#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/unwired.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness that greps a
# captured output stream and is wired to nothing — neither the gate
# library nor a verify call. The wiring meta-harness reads this file as
# text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'expected token' "${stderr_file}"
}

function main() {
  run_scenario
}

main "$@"
