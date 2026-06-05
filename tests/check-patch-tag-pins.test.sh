#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-patch-tag-pins.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-patch-tag-pins"

LINT_PATHS_OVERRIDE="${FIXTURES}/good.yml" bash "${SCRIPT}"
printf 'OK   good.yml\n'

got_exit=0
LINT_PATHS_OVERRIDE="${FIXTURES}/bad.yml" bash "${SCRIPT}" 2>/dev/null || got_exit=$?
if ((got_exit == 0)); then
  printf 'FAIL bad.yml: expected non-zero exit\n' >&2
  exit 1
fi
printf 'OK   bad.yml (exit %d)\n' "${got_exit}"

printf 'all tests passed\n'
