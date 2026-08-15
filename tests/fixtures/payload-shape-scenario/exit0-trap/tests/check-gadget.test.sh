#!/usr/bin/env bash
# tests/check-gadget.test.sh
#
# Counterexample fixture. This scenario asserts exit 0, not exit 2 — the
# script has no malformed-payload shape gate at all. Its message merely
# contains the digit 2 and the word "malformed" as prose, inside a
# single quoted string, never as the call's own bare exit-code argument.
# A matcher keyed on any ' 2 ' substring in the file is fooled by this
# and calls the subject covered; a matcher anchored to the actual
# positional exit-code argument of the scenario call is not.

run_scenario 'malformed field count is reported as a clean pass' \
  'weird.json' 0 'malformed payload: 2 offending fields, exit clean'
