#!/usr/bin/env bash
# tests/fixtures/test-harnesses/good/check-alpha.test.sh
#
# Census fixture: a harness that names its subject through a SCRIPT=
# assignment pointing into scripts/, and reaches its fixture directory
# through a path literal. The census reads this file as text; it is never
# executed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT="${REPO_ROOT}/scripts/check-alpha.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/alpha"

printf '%s %s\n' "${SCRIPT}" "${FIXTURES}"
