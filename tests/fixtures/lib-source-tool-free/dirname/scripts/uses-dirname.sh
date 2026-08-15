#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"
log_info 'fixture'
