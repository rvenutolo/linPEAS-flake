#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/idiom-filter/quiet-alpha.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: one of two unwired
# harnesses beside a text-extracting sibling, so the reported count states
# how many files the assertion idiom actually selected. The meta-harness
# reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'alpha token' "${stderr_file}"
}

function main() {
  run_scenario
}

main "$@"
