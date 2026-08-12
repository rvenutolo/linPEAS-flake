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

# --- Test 5: unknown status aborts, with no file mutation ---
cp "${BEFORE}" "${WORK}/unknown.yml"
UNKNOWN_SNAPSHOT="${WORK}/unknown.snapshot"
cp "${WORK}/unknown.yml" "${UNKNOWN_SNAPSHOT}"
INV_UNKNOWN="${WORK}/unknown-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\tv3.36.0\tWEIRD\n' \
    "${WORK}/unknown.yml"
} >"${INV_UNKNOWN}"
unknown_exit=0
unknown_err="$(bash "${SCRIPT}" --inventory "${INV_UNKNOWN}" 2>&1)" || unknown_exit=$?
if ((unknown_exit == 0)); then
  printf 'FAIL: unknown status should have caused non-zero exit\n' >&2
  exit 1
fi
if [[ ${unknown_err} != *"abort (unknown status"* ]]; then
  printf 'FAIL: unknown-status abort missing message\n  got: %s\n' "${unknown_err}" >&2
  exit 1
fi
if ! diff -u "${UNKNOWN_SNAPSHOT}" "${WORK}/unknown.yml"; then
  printf 'FAIL: unknown.yml was mutated despite unknown-status abort\n' >&2
  exit 1
fi

# --- Test 6: missing target file aborts (status OK, path nonexistent) ---
INV_MISSING="${WORK}/missing-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s/does-not-exist.yml\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\tv3.36.0\tOK\n' \
    "${WORK}"
} >"${INV_MISSING}"
missing_exit=0
missing_err="$(bash "${SCRIPT}" --inventory "${INV_MISSING}" 2>&1)" || missing_exit=$?
# A recorded file that is not there was never read, so the run has no
# verdict about its pin comments: that is a could-not-run, not a rejected
# inventory row, and the two must not share an exit code.
if ((missing_exit != 2)); then
  printf 'FAIL: missing target file should have exited 2, got %d\n' \
    "${missing_exit}" >&2
  exit 1
fi
if [[ ${missing_err} != *"abort (file missing)"* ]]; then
  printf 'FAIL: file-missing abort missing message\n  got: %s\n' "${missing_err}" >&2
  exit 1
fi

# --- Test 7: final OK row lacking a trailing newline is still applied ---
# An inventory truncated mid-write keeps every byte of its last row but
# loses the terminating newline. That row is real work and must be
# applied, not silently dropped.
cp "${BEFORE}" "${WORK}/eof-ok.yml"
INV_EOF_OK="${WORK}/eof-ok-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\tv3.36.0\tOK\n' \
    "${WORK}/eof-ok.yml"
  # Deliberately unterminated: the final row carries no trailing newline.
  printf '%s\t5\tgithub/codeql-action/analyze\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\tv3.36.0\tOK' \
    "${WORK}/eof-ok.yml"
} >"${INV_EOF_OK}"

bash "${SCRIPT}" --inventory "${INV_EOF_OK}" 2>/dev/null

if ! grep --fixed-strings --quiet \
  'analyze@03e4368ac7daa2bd82b3e85262f3bf87ee112f57 # v3.36.0' \
  "${WORK}/eof-ok.yml"; then
  printf 'FAIL: unterminated final OK row was dropped instead of applied\n' >&2
  exit 1
fi
if ! diff -u "${EXPECTED}" "${WORK}/eof-ok.yml"; then
  printf 'FAIL: unterminated-final-row rewrite did not match expected-after.yml\n' >&2
  exit 1
fi

# --- Test 8: final API_FAILURE row lacking a trailing newline aborts ---
# The abort-before-mutation contract must not depend on the inventory's
# last byte being a newline.
cp "${BEFORE}" "${WORK}/eof-apifail.yml"
EOF_APIFAIL_SNAPSHOT="${WORK}/eof-apifail.snapshot"
cp "${WORK}/eof-apifail.yml" "${EOF_APIFAIL_SNAPSHOT}"

INV_EOF_APIFAIL="${WORK}/eof-apifail-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\tv3.36.0\tOK\n' \
    "${WORK}/eof-apifail.yml"
  # Deliberately unterminated: the final row carries no trailing newline.
  printf '%s\t5\tgithub/codeql-action/analyze\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\t\tAPI_FAILURE' \
    "${WORK}/eof-apifail.yml"
} >"${INV_EOF_APIFAIL}"

eof_apifail_exit=0
eof_apifail_err="$(bash "${SCRIPT}" --inventory "${INV_EOF_APIFAIL}" 2>&1)" ||
  eof_apifail_exit=$?
if ((eof_apifail_exit == 0)); then
  printf 'FAIL: unterminated final API_FAILURE row should have caused non-zero exit\n' >&2
  exit 1
fi
if [[ ${eof_apifail_err} != *"abort (api failure in inventory): ${WORK}/eof-apifail.yml:5"* ]]; then
  printf 'FAIL: unterminated-final-row api-failure abort missing message\n  got: %s\n' \
    "${eof_apifail_err}" >&2
  exit 1
fi
if ! diff -u "${EOF_APIFAIL_SNAPSHOT}" "${WORK}/eof-apifail.yml"; then
  printf 'FAIL: eof-apifail.yml was mutated despite unterminated-final-row api-failure abort\n' >&2
  exit 1
fi

# --- Test 9: an inventory that is not there is a tooling error ---
# Every abort above rejects an inventory the script read. An inventory it
# could not read at all is a different failure: exit 2 keeps it out of the
# rejection bucket, so an operator is not sent hunting for a bad row in a
# file that was never opened.
INV_ABSENT="${WORK}/no-such-inventory.tsv"
absent_exit=0
absent_err="$(bash "${SCRIPT}" --inventory "${INV_ABSENT}" 2>&1)" || absent_exit=$?
if ((absent_exit != 2)); then
  printf 'FAIL: absent inventory should exit 2, got %d\n  stderr: %s\n' \
    "${absent_exit}" "${absent_err}" >&2
  exit 1
fi
if [[ ${absent_err} != *"inventory not found"* ]]; then
  printf 'FAIL: absent-inventory message missing\n  got: %s\n' "${absent_err}" >&2
  exit 1
fi

# --- Test 10: an inventory that exists but cannot be read is a tooling error ---
# Existence and readability are different questions, and only the first is
# asked before the rows are pulled. An unreadable inventory carrying the very
# API_FAILURE row that aborts a readable run instead completed at exit 0
# reporting `done: 0 applied, 0 skipped` — the rejection never happened and
# nothing said so.
cp "${BEFORE}" "${WORK}/unreadable.yml"
INV_UNREADABLE="${WORK}/unreadable-inventory.tsv"
{
  printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n'
  printf '%s\t4\tgithub/codeql-action/init\t03e4368ac7daa2bd82b3e85262f3bf87ee112f57\tv3\t\tAPI_FAILURE\n' \
    "${WORK}/unreadable.yml"
} >"${INV_UNREADABLE}"
chmod 000 "${INV_UNREADABLE}"
unreadable_exit=0
unreadable_err="$(bash "${SCRIPT}" --inventory "${INV_UNREADABLE}" 2>&1)" || unreadable_exit=$?
chmod 644 "${INV_UNREADABLE}"
if ((unreadable_exit != 2)); then
  printf 'FAIL: unreadable inventory should exit 2, got %d\n  stderr: %s\n' \
    "${unreadable_exit}" "${unreadable_err}" >&2
  exit 1
fi
if [[ ${unreadable_err} != *"inventory not readable"* ]]; then
  printf 'FAIL: unreadable-inventory message missing\n  got: %s\n' "${unreadable_err}" >&2
  exit 1
fi

# --- Test 11: an inventory with a header and no rows is a tooling error ---
# A readable inventory that enumerated nothing produces the same completed
# run an inventory of genuinely-compliant pins does, so the row count is
# asserted rather than reported.
INV_HEADER_ONLY="${WORK}/header-only-inventory.tsv"
printf 'file\tline\tref\tpinned_sha\tcurrent_comment\ttarget_comment\tstatus\n' \
  >"${INV_HEADER_ONLY}"
header_only_exit=0
header_only_err="$(bash "${SCRIPT}" --inventory "${INV_HEADER_ONLY}" 2>&1)" || header_only_exit=$?
if ((header_only_exit != 2)); then
  printf 'FAIL: header-only inventory should exit 2, got %d\n  stderr: %s\n' \
    "${header_only_exit}" "${header_only_err}" >&2
  exit 1
fi
if [[ ${header_only_err} != *"inventory carries no rows"* ]]; then
  printf 'FAIL: header-only-inventory message missing\n  got: %s\n' "${header_only_err}" >&2
  exit 1
fi

# --- Test 12: an empty inventory is accepted with the opt-in set ---
# The breadth assertion fires on every run, so a caller that means to apply
# an empty inventory says so rather than being told to stop.
allow_empty_exit=0
allow_empty_out="$(LINT_ALLOW_EMPTY_SCAN=1 bash "${SCRIPT}" \
  --inventory "${INV_HEADER_ONLY}" 2>&1)" || allow_empty_exit=$?
if ((allow_empty_exit != 0)); then
  printf 'FAIL: header-only inventory with the opt-in should exit 0, got %d\n  output: %s\n' \
    "${allow_empty_exit}" "${allow_empty_out}" >&2
  exit 1
fi
if [[ ${allow_empty_out} != *"done: 0 applied, 0 skipped"* ]]; then
  printf 'FAIL: opt-in empty run did not report a completed run\n  got: %s\n' \
    "${allow_empty_out}" >&2
  exit 1
fi

printf 'all tests passed\n'
