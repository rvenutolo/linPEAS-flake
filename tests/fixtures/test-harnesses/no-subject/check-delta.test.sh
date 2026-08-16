#!/usr/bin/env bash
# tests/fixtures/test-harnesses/no-subject/check-delta.test.sh
#
# Census fixture: a harness that names no subject at all. It holds a path
# into scripts/, but under a variable the census does not read, and it
# carries no header annotation — so nothing here says what it exercises.
# The census reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly TARGET="${REPO_ROOT}/scripts/check-delta.sh"

printf '%s\n' "${TARGET}"
