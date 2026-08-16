#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/parity-stray/stray-parity.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a fully wired harness
# that registers a parity exemption without being on the reviewed
# allowlist, excusing a collapsed pair nobody named. The meta-harness
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
  harness_assert_parity_exempt 'first' 'second' 'the two runs look the same'
}

function main() {
  run_scenario
  harness_assert_verify
}

main "$@"
