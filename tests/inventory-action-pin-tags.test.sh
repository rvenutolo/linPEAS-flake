#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/inventory-action-pin-tags.sh"
readonly FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/inventory-action-pin-tags"
readonly EXPECTED="${FIXTURE_DIR}/expected.tsv"
readonly INPUT="tests/fixtures/inventory-action-pin-tags/sample-workflow.yml"

OUT="$(mktemp)"
trap 'rm -f "${OUT}"' EXIT

cd "${REPO_ROOT}"

INVENTORY_PATHS_OVERRIDE="${INPUT}" \
  INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
  bash "${SCRIPT}" --output "${OUT}"

if ! diff -u "${EXPECTED}" "${OUT}"; then
  printf 'FAIL: inventory output diverged from expected fixture\n' >&2
  exit 1
fi

printf 'all tests passed\n'
