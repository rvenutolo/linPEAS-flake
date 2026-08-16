#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/exempt-skipped/refresh-just-recipes.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness whose
# basename is on the meta-harness's out-of-scope list. It greps a captured
# output stream without wiring, registers a discrimination exemption, and
# registers a parity exemption it is not allowlisted for — three separate
# detections, every one of them suppressed because the basename is out of
# scope. The meta-harness reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'expected token' "${stderr_file}"
  harness_assert_exempt 'expected token' '*' 'every scenario prints this banner'
  harness_assert_parity_exempt 'first' 'second' 'no honest output separates the pair'
}

function main() {
  run_scenario
}

main "$@"
