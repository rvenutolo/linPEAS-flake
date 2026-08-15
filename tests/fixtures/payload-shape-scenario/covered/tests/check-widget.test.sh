#!/usr/bin/env bash
# tests/check-widget.test.sh
#
# Fixture harness for check-widget.sh. Not executed by the payload-shape
# -scenario lint's own harness — only its text is scanned, the same way
# the lint under test reads a real subject's paired harness.

run_scenario 'well-formed widget payload passes' \
  'good.json' 0 'widget OK'

# A malformed widget payload is a could-not-run, not a fabricated pass.
run_scenario 'malformed widget payload is a tooling error' \
  'bad.json' 2 'malformed payload from WIDGET_JSON_OVERRIDE'
