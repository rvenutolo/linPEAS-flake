#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/exempting.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a fully wired harness
# that nonetheless registers a discrimination exemption, weakening one of
# its own assertions. The wiring meta-harness reads this file as text; it
# is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"

function run_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  grep --fixed-strings --quiet -- 'shared banner' "${stderr_file}"
  harness_assert_record 'scenario' 'shared banner' "${stderr_file}"
  harness_assert_exempt 'scenario' 'shared banner' 'every scenario prints this banner'
}

function main() {
  run_scenario
  harness_assert_verify
}

main "$@"
