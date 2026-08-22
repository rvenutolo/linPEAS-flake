#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="/opt/fixed-checkout"
readonly REPO_ROOT
printf '%s\n' "${REPO_ROOT}"
