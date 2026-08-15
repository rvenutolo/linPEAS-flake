# Fixture: the banned shape inside a sourced library rather than a
# top-level script. The helper this rule points at lives in such a
# library, so a scan that stops at the top level cannot see its neighbors.
# shellcheck shell=bash

lib_source='RENOVATE_JSON_OVERRIDE'
printf '%s\n' "${lib_source}"
