#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/comment-mention.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness that greps a
# captured output stream and names both halves of the wiring only inside
# comments. It never sources scripts/lib/harness-assert.sh and never
# calls harness_assert_verify, so nothing is ever recorded or checked.
# The wiring meta-harness reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'expected token' "${stderr_file}"
  # harness_assert_record 'scenario' 'expected token' "${stderr_file}"
}

function main() {
  run_scenario
  # harness_assert_verify
}

main "$@"
