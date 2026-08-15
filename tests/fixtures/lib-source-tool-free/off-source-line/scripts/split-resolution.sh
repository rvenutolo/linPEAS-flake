#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
log_info 'fixture'
