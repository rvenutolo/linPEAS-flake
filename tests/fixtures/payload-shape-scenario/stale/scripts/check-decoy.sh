#!/usr/bin/env bash
# scripts/check-decoy.sh
#
# @description Fixture non-subject carrying a stale exemption marker: it
# reads no external payload, so the marker below excuses nothing and
# must be reported as drift.
# payload-subject-exempt: stale — nothing here actually reads an external payload
set -Eeuo pipefail
IFS=$'\n\t'

printf 'decoy: no external payload read here\n'
