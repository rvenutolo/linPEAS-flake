#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
printf '%s\n' "${REPO_ROOT}"
