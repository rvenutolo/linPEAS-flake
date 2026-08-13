#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/lib/awk-path.sh"

a="first.txt"
b="second.txt"
awk 'p' "$(awk_path "${a}")" "${b}"
