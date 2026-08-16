#!/usr/bin/env bash
# tests/fixtures/harness-assert-wired/verify-mention/verify-mention.test.sh
#
# Fixture for tests/_harness_assert_wired.test.sh: a harness that greps a
# captured output stream, sources the gate library, and names the
# verification step only inside a printf argument. The name sits on a code
# line rather than in a comment, so blanking comments does not hide it —
# only the statement anchor separates naming the call from making it. The
# meta-harness reads this file as text; it is never executed.

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
  printf 'the gate is closed by %s\n' 'harness_assert_verify'
}

main "$@"
