#!/usr/bin/env bash
# tests/check-gizmo.test.sh
#
# Fixture harness for check-gizmo.sh. Only the well-formed path and the
# absent-input path are exercised here — the tooling-error path this
# lint requires is deliberately missing, which is the gap the
# payload-shape-scenario lint exists to catch.

run_scenario 'well-formed gizmo payload passes' \
  'good.json' 0 'gizmo OK'

run_scenario 'gizmo payload absent fails' \
  'absent' 1 'gizmo missing'
