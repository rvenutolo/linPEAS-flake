#!/usr/bin/env bash
# scripts/refresh-nothing.sh
#
# @description Fixture non-subject: touches no external payload source,
# so the payload-shape-scenario predicate matches nothing under this
# scan root.
set -Eeuo pipefail
IFS=$'\n\t'

printf 'nothing to refresh\n'
