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

# Each scenario is recorded as its whole observable outcome: the exit code,
# stdout, stderr, and the inventory file the run was asked to write — that
# file is the run's product, so it belongs in the comparison pool alongside
# the streams.
OUT="$(mktemp)"
OUT_STDOUT="$(mktemp)"
OUT_STDERR="$(mktemp)"
OUT_OUTCOME="$(mktemp)"
trap 'rm --force -- "${OUT}" "${OUT_STDOUT}" "${OUT_STDERR}" "${OUT_OUTCOME}"' EXIT

cd "${REPO_ROOT}"

rc=0
INVENTORY_PATHS_OVERRIDE="${INPUT}" \
  INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
  bash "${SCRIPT}" --output "${OUT}" >"${OUT_STDOUT}" 2>"${OUT_STDERR}" || rc=$?
printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${OUT_OUTCOME}"
harness_assert_record 'inventory output matches expected fixture' '' \
  "${OUT_OUTCOME}" "${OUT_STDOUT}" "${OUT_STDERR}" "${OUT}"

if ((rc != 0)); then
  printf 'FAIL: inventory run exited %d\n' "${rc}" >&2
  cat -- "${OUT_STDERR}" >&2
  exit 1
fi
if ! diff -u "${EXPECTED}" "${OUT}"; then
  printf 'FAIL: inventory output diverged from expected fixture\n' >&2
  exit 1
fi

# --- NO_PATCH_TAG: a pin whose SHA has no matching tag in the fixture ---
OUT_NOPATCH="$(mktemp)"
NOPATCH_STDOUT="$(mktemp)"
NOPATCH_STDERR="$(mktemp)"
NOPATCH_OUTCOME="$(mktemp)"
nopatch_exit=0
INVENTORY_PATHS_OVERRIDE="tests/fixtures/inventory-action-pin-tags/nopatch-workflow.yml" \
  INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
  bash "${SCRIPT}" --output "${OUT_NOPATCH}" \
  >"${NOPATCH_STDOUT}" 2>"${NOPATCH_STDERR}" || nopatch_exit=$?
printf 'harness-assert-outcome: exit=%d\n' "${nopatch_exit}" >"${NOPATCH_OUTCOME}"
harness_assert_record 'NO_PATCH_TAG row emitted' 'NO_PATCH_TAG' \
  "${NOPATCH_OUTCOME}" "${NOPATCH_STDOUT}" "${NOPATCH_STDERR}" "${OUT_NOPATCH}"
if ((nopatch_exit != 0)) || ! grep --quiet 'NO_PATCH_TAG' "${OUT_NOPATCH}"; then
  printf 'FAIL: NO_PATCH_TAG row not emitted (exit %d)\n' "${nopatch_exit}" >&2
  cat -- "${OUT_NOPATCH}" "${NOPATCH_STDERR}" >&2
  rm --force -- "${OUT_NOPATCH}" "${NOPATCH_STDOUT}" "${NOPATCH_STDERR}" \
    "${NOPATCH_OUTCOME}"
  exit 1
fi
rm --force -- "${OUT_NOPATCH}" "${NOPATCH_STDOUT}" "${NOPATCH_STDERR}" \
  "${NOPATCH_OUTCOME}"

# --- API_FAILURE: no fixture dir; stub gh to fail -> exit 1 + API_FAILURE row ---
# The stderr message and the API_FAILURE row are two properties of one run, so
# they are one record carrying two asserted substrings. Recording the run once
# per property would make those records byte-identical siblings that no
# substring can separate.
STUB_DIR="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "gh: simulated API failure" >&2\nexit 1\n' >"${STUB_DIR}/gh"
chmod +x "${STUB_DIR}/gh"
OUT_APIFAIL="$(mktemp)"
ERR_APIFAIL="$(mktemp)"
STDOUT_APIFAIL="$(mktemp)"
OUTCOME_APIFAIL="$(mktemp)"
api_exit=0
PATH="${STUB_DIR}:${PATH}" \
  INVENTORY_PATHS_OVERRIDE="tests/fixtures/inventory-action-pin-tags/apifail-workflow.yml" \
  bash "${SCRIPT}" --output "${OUT_APIFAIL}" \
  >"${STDOUT_APIFAIL}" 2>"${ERR_APIFAIL}" || api_exit=$?
printf 'harness-assert-outcome: exit=%d\n' "${api_exit}" >"${OUTCOME_APIFAIL}"
harness_assert_record 'API failure reported on stderr and as a row' \
  'inventory: one or more API failures' \
  "${OUTCOME_APIFAIL}" "${STDOUT_APIFAIL}" "${ERR_APIFAIL}" "${OUT_APIFAIL}"
harness_assert_also 'API_FAILURE'
if ((api_exit != 1)); then
  printf 'FAIL: API failure should exit 1, got %d\n' "${api_exit}" >&2
  cat -- "${ERR_APIFAIL}" >&2
  rm --recursive --force -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}" \
    "${STDOUT_APIFAIL}" "${OUTCOME_APIFAIL}"
  exit 1
fi
if ! grep --fixed-strings --quiet 'inventory: one or more API failures' "${ERR_APIFAIL}"; then
  printf 'FAIL: API-failure stderr message missing\n' >&2
  cat -- "${ERR_APIFAIL}" >&2
  rm --recursive --force -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}" \
    "${STDOUT_APIFAIL}" "${OUTCOME_APIFAIL}"
  exit 1
fi
if ! grep --quiet 'API_FAILURE' "${OUT_APIFAIL}"; then
  printf 'FAIL: API_FAILURE row not emitted\n' >&2
  cat -- "${OUT_APIFAIL}" >&2
  rm --recursive --force -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}" \
    "${STDOUT_APIFAIL}" "${OUTCOME_APIFAIL}"
  exit 1
fi
rm --recursive --force -- "${STUB_DIR}" "${OUT_APIFAIL}" "${ERR_APIFAIL}" \
  "${STDOUT_APIFAIL}" "${OUTCOME_APIFAIL}"

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
STDOUT_ACTIONYAML="$(mktemp)"
STDERR_ACTIONYAML="$(mktemp)"
OUTCOME_ACTIONYAML="$(mktemp)"
actionyaml_exit=0
(
  cd "${ACTIONYAML_DIR}" &&
    INVENTORY_TAG_FIXTURE_DIR="${FIXTURE_DIR}/tag-fixtures" \
      bash "${SCRIPT}" --output "${OUT_ACTIONYAML}"
) >"${STDOUT_ACTIONYAML}" 2>"${STDERR_ACTIONYAML}" || actionyaml_exit=$?
printf 'harness-assert-outcome: exit=%d\n' "${actionyaml_exit}" >"${OUTCOME_ACTIONYAML}"
harness_assert_record 'action.yaml composite inventoried via default scan' \
  'action.yaml' "${OUTCOME_ACTIONYAML}" "${STDOUT_ACTIONYAML}" \
  "${STDERR_ACTIONYAML}" "${OUT_ACTIONYAML}"
if ((actionyaml_exit != 0)) || ! grep --quiet 'action.yaml' "${OUT_ACTIONYAML}"; then
  printf 'FAIL: action.yaml composite not inventoried via default scan (exit %d)\n' \
    "${actionyaml_exit}" >&2
  cat -- "${OUT_ACTIONYAML}" "${STDERR_ACTIONYAML}" >&2
  rm --recursive --force -- "${ACTIONYAML_DIR}" "${OUT_ACTIONYAML}" \
    "${STDOUT_ACTIONYAML}" "${STDERR_ACTIONYAML}" "${OUTCOME_ACTIONYAML}"
  exit 1
fi
rm --recursive --force -- "${ACTIONYAML_DIR}" "${OUT_ACTIONYAML}" \
  "${STDOUT_ACTIONYAML}" "${STDERR_ACTIONYAML}" "${OUTCOME_ACTIONYAML}"
printf 'OK   action.yaml composite inventoried via default scan\n'

harness_assert_verify || exit 1

printf 'all tests passed\n'
