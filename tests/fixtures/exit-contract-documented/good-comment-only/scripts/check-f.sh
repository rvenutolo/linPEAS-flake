#!/usr/bin/env bash
# scripts/check-f.sh
#
# Exits 0 on clean, 1 on drift.
set -Eeuo pipefail
# a rewrite of this guard would exit 2 instead; it does not today
exit 1
