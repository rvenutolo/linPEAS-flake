#!/usr/bin/env bash
# scripts/check-gizmo.sh
#
# @description Fixture subject: reads a gizmo payload via
# GIZMO_JSON_OVERRIDE, falling back to `gh api` live. Matches the
# predicate on two independent arms — deliberately, so this fixture's
# exemption scenario stays a subject even when either arm alone is
# mutated away, and only the uncovered fixture (which matches on
# GIZMO_JSON_OVERRIDE alone) loses its subject status when that one arm
# is dropped. Carries a declared exemption below, so its missing
# malformed-payload scenario is not a violation.
# payload-subject-exempt: the fixture payload is maintainer-authored test data, not externally supplied
set -Eeuo pipefail
IFS=$'\n\t'

payload="${GIZMO_JSON_OVERRIDE:-}"
if [[ -z ${payload} ]]; then
  payload="$(gh api gizmos)"
fi
printf '%s\n' "${payload}"
