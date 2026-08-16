#!/usr/bin/env bash
# tests/fixtures/test-harnesses/good/lib-beta.test.sh
# @subject scripts/lib/beta.sh
#
# Census fixture: a harness that names its subject through a header
# annotation because it drives a library rather than a script, and builds
# its tree at runtime so the census renders an em dash in its Fixtures
# column. The census reads this file as text; it is never executed.

set -Eeuo pipefail
IFS=$'\n\t'

work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

printf '%s\n' "${work}"
