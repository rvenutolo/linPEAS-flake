#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/apply-patch-tag-pin-rewrite.sh"
readonly FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/apply-patch-tag-pin-rewrite"
readonly BEFORE="${FIXTURE_DIR}/before.yml"
readonly EXPECTED="${FIXTURE_DIR}/expected-after.yml"
readonly INVENTORY_SRC="${FIXTURE_DIR}/inventory.tsv"
readonly FIXTURE_REL="tests/fixtures/apply-patch-tag-pin-rewrite/before.yml"

cd "${REPO_ROOT}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- Test 1: happy path ---
cp "${BEFORE}" "${WORK}/before.yml"
INV_HAPPY="${WORK}/inventory.tsv"
sed "s#${FIXTURE_REL}#${WORK}/before.yml#g" "${INVENTORY_SRC}" >"${INV_HAPPY}"

bash "${SCRIPT}" --inventory "${INV_HAPPY}"

if ! diff -u "${EXPECTED}" "${WORK}/before.yml"; then
  printf 'FAIL: happy-path rewrite did not match expected-after.yml\n' >&2
  exit 1
fi

# --- Test 2: stale inventory protection ---
# Mutate the working copy so the recorded substring no longer matches.
cp "${BEFORE}" "${WORK}/stale.yml"
sed --in-place \
  's#03e4368ac7daa2bd82b3e85262f3bf87ee112f57#dddddddddddddddddddddddddddddddddddddddd#g' \
  "${WORK}/stale.yml"

# Snapshot the mutated file to verify no partial rewrite occurs.
STALE_SNAPSHOT="${WORK}/stale.snapshot"
cp "${WORK}/stale.yml" "${STALE_SNAPSHOT}"

INV_STALE="${WORK}/stale-inventory.tsv"
sed "s#${FIXTURE_REL}#${WORK}/stale.yml#g" "${INVENTORY_SRC}" >"${INV_STALE}"

if bash "${SCRIPT}" --inventory "${INV_STALE}" 2>/dev/null; then
  printf 'FAIL: stale inventory should have caused non-zero exit\n' >&2
  exit 1
fi

if ! diff -u "${STALE_SNAPSHOT}" "${WORK}/stale.yml"; then
  printf 'FAIL: stale.yml was partially mutated on stale-inventory abort\n' >&2
  exit 1
fi

# --- Test 3: API_FAILURE in inventory aborts ---
cp "${BEFORE}" "${WORK}/apifail.yml"
APIFAIL_SNAPSHOT="${WORK}/apifail.snapshot"
cp "${WORK}/apifail.yml" "${APIFAIL_SNAPSHOT}"

INV_APIFAIL="${WORK}/apifail-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\t\tAPI_FAILURE\n' \
    "${WORK}/apifail.yml"
} >"${INV_APIFAIL}"

if bash "${SCRIPT}" --inventory "${INV_APIFAIL}" 2>/dev/null; then
  printf 'FAIL: API_FAILURE row should have caused non-zero exit\n' >&2
  exit 1
fi

if ! diff -u "${APIFAIL_SNAPSHOT}" "${WORK}/apifail.yml"; then
  printf 'FAIL: apifail.yml was mutated despite API_FAILURE abort\n' >&2
  exit 1
fi

# --- Test 4: NO_PATCH_TAG rows are skipped, others still applied ---
cp "${BEFORE}" "${WORK}/mixed.yml"
INV_MIXED="${WORK}/mixed-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\tv3.36.0\tOK\n' \
    "${WORK}/mixed.yml"
  printf '%s\t5\tgithub/codeql-action/analyze\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\t\tNO_PATCH_TAG\n' \
    "${WORK}/mixed.yml"
} >"${INV_MIXED}"

bash "${SCRIPT}" --inventory "${INV_MIXED}" 2>/dev/null

# Line 4 should be rewritten; line 5 should remain `# v3`.
if ! grep --quiet 'init@03e4368ac7daa2bd82b3e85262f3bf87ee112f57 # v3.36.0' "${WORK}/mixed.yml"; then
  printf 'FAIL: NO_PATCH_TAG-skip test did not apply the OK row\n' >&2
  exit 1
fi
if ! grep --quiet 'analyze@03e4368ac7daa2bd82b3e85262f3bf87ee112f57 # v3$' "${WORK}/mixed.yml"; then
  printf 'FAIL: NO_PATCH_TAG row should have been skipped (line 5 changed)\n' >&2
  exit 1
fi

printf 'all tests passed\n'
