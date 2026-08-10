#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
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
harness_assert_record 'inventory output matches expected fixture' '' "${OUT}"

if ! diff -u "${EXPECTED}" "${OUT}"; then
  printf 'FAIL: inventory output diverged from expected fixture\n' >&2
  exit 1
fi

# --- NO_PATCH_TAG: a pin whose SHA has no matching tag in the fixture ---
OUT_NOPATCH="$(mktemp)"
INVENTORY_PATHS_OVERRIDE="tests/fixtures/inventory-action-pin-tags/nopatch-workflow.yml" \
  INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
  bash "${SCRIPT}" --output "${OUT_NOPATCH}"
harness_assert_record 'NO_PATCH_TAG row emitted' 'NO_PATCH_TAG' "${OUT_NOPATCH}"
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
harness_assert_record 'API failure stderr message' \
  'inventory: one or more API failures' "${ERR_APIFAIL}"
harness_assert_record 'API_FAILURE row emitted' 'API_FAILURE' "${OUT_APIFAIL}"
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

# --- action.yaml composite via default scan (no INVENTORY_PATHS_OVERRIDE):
# fixed once the .github/actions discovery covers action.yaml, not just
# action.yml. ---
ACTIONYAML_DIR="$(mktemp --directory)"
mkdir --parents "${ACTIONYAML_DIR}/.github/actions/sample-yaml"
cat >"${ACTIONYAML_DIR}/.github/actions/sample-yaml/action.yaml" <<'ACTION_EOF'
name: sample-yaml
runs:
  using: composite
  steps:
    - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v5
ACTION_EOF
OUT_ACTIONYAML="$(mktemp)"
(
  cd "${ACTIONYAML_DIR}" &&
    INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
      bash "${SCRIPT}" --output "${OUT_ACTIONYAML}"
)
harness_assert_record 'action.yaml composite inventoried via default scan' \
  'action.yaml' "${OUT_ACTIONYAML}"
if ! grep --quiet 'action.yaml' "${OUT_ACTIONYAML}"; then
  printf 'FAIL: action.yaml composite not inventoried via default scan\n' >&2
  cat -- "${OUT_ACTIONYAML}" >&2
  rm -rf -- "${ACTIONYAML_DIR}" "${OUT_ACTIONYAML}"
  exit 1
fi
rm -rf -- "${ACTIONYAML_DIR}" "${OUT_ACTIONYAML}"
printf 'OK   action.yaml composite inventoried via default scan\n'

harness_assert_verify || exit 1

printf 'all tests passed\n'
