#!/usr/bin/env bash
# scripts/check-i.sh
#
# The manual-UI rows (fork-PR approval gate, maintainer 2FA, merge
# flags) are out of scope, as is anything behind a v2 endpoint.
# Exits 0 on full match, 1 on any drift.
set -Eeuo pipefail
exit 2
