#!/usr/bin/env bash
set -Eeuo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
printf '%s\n' "${REPO_ROOT}"
