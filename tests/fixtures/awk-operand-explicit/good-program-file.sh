#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/lib/awk-path.sh"

LIB="program.awk"
f="data.txt"
awk --file "${LIB}" "$(awk_path "${f}")"
