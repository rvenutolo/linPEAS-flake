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

# --- NO_PATCH_TAG: a pin whose SHA has no matching tag in the fixture ---
OUT_NOPATCH="$(mktemp)"
INVENTORY_PATHS_OVERRIDE="tests/fixtures/inventory-action-pin-tags/nopatch-workflow.yml" \
  INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
  bash "${SCRIPT}" --output "${OUT_NOPATCH}"
if ! grep --quiet 'NO_PATCH_TAG' "${OUT_NOPATCH}"; then
  printf 'FAIL: NO_PATCH_TAG row not emitted\n' >&2
  cat -- "${OUT_NOPATCH}" >&2
  rm -f -- "${OUT_NOPATCH}"
  exit 1
fi
rm -f -- "${OUT_NOPATCH}"

# --- API_FAILURE: no fixture dir; stub gh to fail -> exit 1 + API_FAILURE row ---
STUB_DIR="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "gh: simulated API failure" >&2\nexit 1\n' >"${STUB_DIR}/gh"
chmod +x "${STUB_DIR}/gh"
OUT_APIFAIL="$(mktemp)"
ERR_APIFAIL="$(mktemp)"
api_exit=0
PATH="${STUB_DIR}:${PATH}" \
  INVENTORY_PATHS_OVERRIDE="tests/fixtures/inventory-action-pin-tags/apifail-workflow.yml" \
  bash "${SCRIPT}" --output "${OUT_APIFAIL}" 2>"${ERR_APIFAIL}" || api_exit=$?
if ((api_exit != 1)); then
  printf 'FAIL: API failure should exit 1, got %d\n' "${api_exit}" >&2
  cat -- "${ERR_APIFAIL}" >&2
  rm -rf -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}"
  exit 1
fi
if ! grep --fixed-strings --quiet 'inventory: one or more API failures' "${ERR_APIFAIL}"; then
  printf 'FAIL: API-failure stderr message missing\n' >&2
  cat -- "${ERR_APIFAIL}" >&2
  rm -rf -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}"
  exit 1
fi
if ! grep --quiet 'API_FAILURE' "${OUT_APIFAIL}"; then
  printf 'FAIL: API_FAILURE row not emitted\n' >&2
  cat -- "${OUT_APIFAIL}" >&2
  rm -rf -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}"
  exit 1
fi
rm -rf -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}"

printf 'all tests passed\n'
