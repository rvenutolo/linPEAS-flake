#!/usr/bin/env bash
# Fixture: the banned shape under a marker with no rationale. An
# exemption nobody has to justify is a way to switch the rule off, so the
# empty marker excuses nothing and the assignment is still reported.
set -Eeuo pipefail
IFS=$'\n\t'

# payload-source-exempt:
unmarked_source='RENOVATE_JSON_OVERRIDE'
printf '%s\n' "${unmarked_source}"
