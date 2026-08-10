#!/usr/bin/env bash
# tests/compare-repro.test.sh
#
# Failure-mode harness for scripts/compare-repro.sh.
# Mirrors tests/check-protect-main.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/compare-repro.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/compare-repro"

failures=0

# The runbook link rides on the MISMATCH verdict, so every mismatch fixture
# prints it and no match fixture does. It separates the mismatch class from
# the match class, which is the axis this assertion is about; it cannot
# separate one mismatch fixture from another.
harness_assert_exempt 'docs/runbooks/reproducibility-check.md' '*' \
  'printed on every MISMATCH verdict and on no MATCH verdict'

# @arg $1 scenario name
# @arg $2 fixture subdir (must contain build-a.json + build-b.json)
# @arg $3 expected exit
# @arg $4 expected stdout/summary substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_substring="$4"

  local summary_file
  summary_file="$(mktemp)"

  local actual_exit=0
  GITHUB_STEP_SUMMARY="${summary_file}" \
    "${SCRIPT}" \
    "${FIXTURES}/${fixture_dir}/build-a.json" \
    "${FIXTURES}/${fixture_dir}/build-b.json" \
    >/dev/null 2>&1 || actual_exit=$?
  harness_assert_record "${name}" "${expected_substring}" "${summary_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'summary was:\n' >&2
    cat -- "${summary_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_substring} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_substring}" "${summary_file}"; then
    printf 'FAIL: %s — summary missing %q\n' "${name}" "${expected_substring}" >&2
    printf 'summary was:\n' >&2
    cat -- "${summary_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
}

# Every summary tabulates all three field names and the word MATCH inside
# `**MISMATCH**`, so a bare field name or `MATCH` matches on every path.
# The verdict line is what separates the outcomes.
run_scenario \
  'match: identical hashes → exit 0, summary contains MATCH' \
  'match' \
  0 \
  '**Result:** MATCH — builds are reproducible.'

run_scenario \
  'mismatch-store: differing linpeas_nar_hash → exit 1, summary names field' \
  'mismatch-store' \
  1 \
  '**Result:** MISMATCH in: linpeas_nar_hash'

run_scenario \
  'mismatch-image: differing image_tar_sha256 → exit 1, summary names field' \
  'mismatch-image' \
  1 \
  '**Result:** MISMATCH in: image_tar_sha256'

run_scenario \
  'mismatch: runbook link present in summary' \
  'mismatch-store' \
  1 \
  'docs/runbooks/reproducibility-check.md'

run_scenario \
  'store-path-only diff: not a mismatch (paths informational only) → exit 0' \
  'store-path-only-diff' \
  0 \
  '**Result:** MATCH — builds are reproducible.'

# Custom scenario: missing input file → exit 2
function run_missing_input_scenario() {
  local stderr_file
  stderr_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" "${FIXTURES}/nonexistent-a.json" "${FIXTURES}/nonexistent-b.json" \
    >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record 'missing-input' 'does not exist' "${stderr_file}"
  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: missing-input — expected exit 2, got %d\n' "${actual_exit}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet 'does not exist' "${stderr_file}"; then
    printf 'FAIL: missing-input — stderr missing expected diagnostic\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: missing-input → exit 2\n'
  fi
}

run_missing_input_scenario

# @description Run a bad-input scenario: the script must exit 2 before
# writing any summary, with the offending field named on stderr.
# @arg $1 scenario name
# @arg $2 fixture subdir
# @arg $3 expected stderr substring
function run_bad_input_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_substring="$3"

  local summary_file stderr_file
  summary_file="$(mktemp)"
  stderr_file="$(mktemp)"

  local actual_exit=0
  GITHUB_STEP_SUMMARY="${summary_file}" \
    "${SCRIPT}" \
    "${FIXTURES}/${fixture_dir}/build-a.json" \
    "${FIXTURES}/${fixture_dir}/build-b.json" \
    >/dev/null 2>"${stderr_file}" || actual_exit=$?
  harness_assert_record "${name}" "${expected_substring}" \
    "${stderr_file}" "${summary_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_substring}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_substring}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -s ${summary_file} ]]; then
    printf 'FAIL: %s — wrote a summary despite bad input\n' "${name}" >&2
    cat -- "${summary_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit 2)\n' "${name}"
  fi
}

# The diagnostic must name both the offending file and the offending
# field: the field name alone appears in every summary this harness
# captures, and the rejection reason alone would not tie the failure to
# the fixture that provoked it.
run_bad_input_scenario \
  'absent hash field is not a match' \
  'missing-field' \
  'missing-field/build-a.json: field linpeas_nar_hash is absent, null, or empty'

run_bad_input_scenario \
  'JSON-null hash field is not a match' \
  'null-field' \
  'null-field/build-a.json: field linpeas_nar_hash is absent, null, or empty'

run_bad_input_scenario \
  'literal null-string hash field is not a match' \
  'literal-null-string' \
  'literal-null-string/build-a.json: field linpeas_nar_hash is absent, null, or empty'

run_bad_input_scenario \
  'malformed hash value is not a match' \
  'bad-shape' \
  'bad-shape/build-a.json: field linpeas_nar_hash has malformed value'

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi

printf '\nall scenarios passed.\n'
