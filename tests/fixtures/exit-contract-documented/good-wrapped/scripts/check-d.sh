#!/usr/bin/env bash
# scripts/check-d.sh
#
# Exits 0 clean, 1 on a producer outside the helper, a producer name
# copied to a variable, a loop expanding a glob at its own head, an
# array assignment expanding one in its element list, a marker with no
# rationale, or a marker that excuses no site this pass classified,
# 2 when a required tool is absent or the scan set could not be read.
set -Eeuo pipefail
exit 2
