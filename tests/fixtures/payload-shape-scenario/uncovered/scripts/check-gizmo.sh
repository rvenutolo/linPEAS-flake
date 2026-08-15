#!/usr/bin/env bash
# scripts/check-gizmo.sh
#
# @description Fixture subject: reads a gizmo payload via
# GIZMO_JSON_OVERRIDE. Unlike check-widget.sh, its paired harness never
# exercises the malformed-input path — that is the gap this fixture
# exists to represent.
set -Eeuo pipefail
IFS=$'\n\t'

payload="${GIZMO_JSON_OVERRIDE:?GIZMO_JSON_OVERRIDE is required}"
printf '%s\n' "${payload}"
