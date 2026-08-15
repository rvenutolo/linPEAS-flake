#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(git rev-parse --show-toplevel)/scripts/lib/log.sh"
log_info 'fixture'
