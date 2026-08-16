#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/idiom-filter/plain-grep.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness wired to
# nothing whose only grep extracts text instead of testing for a match.
# Extraction is not the repo's assertion idiom, so the wiring verdict
# never reaches this file and no diagnostic names it. The meta-harness
# reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

function run_scenario() {
  local stderr_file matched
  stderr_file="$(mktemp)"
  matched="$(grep --fixed-strings 'expected token' "${stderr_file}")"
  printf '%s\n' "${matched}"
}

function main() {
  run_scenario
}

main "$@"
