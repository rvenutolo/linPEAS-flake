#!/usr/bin/env bash
# tests/compare-repro.test.sh
#
# Failure-mode harness for scripts/compare-repro.sh.
# Fixture-driven: each scenario asserts exit code and output.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/compare-repro.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/compare-repro"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir (must contain build-a.json + build-b.json)
# @arg $3 expected exit
# @arg $4 expected stdout/summary substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_substring="$4"

  local summary_file stdout_file stderr_file outcome_file
  summary_file="$(mktemp)"
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  GITHUB_STEP_SUMMARY="${summary_file}" \
    "${SCRIPT}" \
    "${FIXTURES}/${fixture_dir}/build-a.json" \
    "${FIXTURES}/${fixture_dir}/build-b.json" \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_substring}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}" "${summary_file}"

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

  rm --force -- "${summary_file}" "${stdout_file}" "${stderr_file}" \
    "${outcome_file}"
}

# Every summary tabulates all three field names and the word MATCH inside
# `**MISMATCH**`, so a bare field name or `MATCH` matches on every path.
# The verdict line is what separates the outcomes. Each verdict assertion
# carries the terminating period, so a single-field verdict cannot be
# satisfied by the opening of a multi-field one.
run_scenario \
  'match: identical hashes → exit 0, summary contains MATCH' \
  'match' \
  0 \
  '**Result:** MATCH — builds are reproducible.'

run_scenario \
  'mismatch-store: differing linpeas_nar_hash → exit 1, summary names field' \
  'mismatch-store' \
  1 \
  '**Result:** MISMATCH in: linpeas_nar_hash.'

run_scenario \
  'mismatch-image: differing image_tar_sha256 → exit 1, summary names field' \
  'mismatch-image' \
  1 \
  '**Result:** MISMATCH in: image_tar_sha256.'

run_scenario \
  'mismatch in both fields: summary names both' \
  'mismatch-both' \
  1 \
  '**Result:** MISMATCH in: linpeas_nar_hash image_tar_sha256.'

run_scenario \
  'store-path-only diff: not a mismatch (paths informational only) → exit 0' \
  'store-path-only-diff' \
  0 \
  '**Result:** MATCH — builds are reproducible.'

# Custom scenario: missing input file → exit 2
function run_missing_input_scenario() {
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" "${FIXTURES}/nonexistent-a.json" "${FIXTURES}/nonexistent-b.json" \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record 'missing-input' 'does not exist' \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
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

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
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

  local summary_file stderr_file stdout_file outcome_file
  summary_file="$(mktemp)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  GITHUB_STEP_SUMMARY="${summary_file}" \
    "${SCRIPT}" \
    "${FIXTURES}/${fixture_dir}/build-a.json" \
    "${FIXTURES}/${fixture_dir}/build-b.json" \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_substring}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}" "${summary_file}"

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

  rm --force -- "${summary_file}" "${stderr_file}" "${stdout_file}" \
    "${outcome_file}"
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

# @description Run the script under en_US.UTF-8 on two copies of the
# match fixture that set one field to the same value, and compare exit
# code and the whole of stderr. In that locale a bash range such as
# `[0-9a-f]` or `[A-Za-z0-9+/=]` also matches non-ASCII characters, and
# two builds that measured the same malformed value would compare equal.
# @arg $1 scenario name  @arg $2 field  @arg $3 value
function run_en_us_scenario() {
  local -r name="$1" field="$2" value="$3"
  local dir summary_file stderr_file stdout_file outcome_file want
  dir="$(mktemp --directory)"
  summary_file="$(mktemp)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  jq --arg k "${field}" --arg v "${value}" '.[$k] = $v' \
    -- "${FIXTURES}/match/build-a.json" >"${dir}/build-a.json"
  jq --arg k "${field}" --arg v "${value}" '.[$k] = $v' \
    -- "${FIXTURES}/match/build-b.json" >"${dir}/build-b.json"
  want="ERROR: ${dir}/build-a.json: field ${field} has malformed value: ${value}"

  local actual_exit=0
  LC_ALL=en_US.UTF-8 GITHUB_STEP_SUMMARY="${summary_file}" \
    "${SCRIPT}" "${dir}/build-a.json" "${dir}/build-b.json" \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}" "${summary_file}"

  if [[ ${actual_exit} -ne 2 || "$(cat -- "${stderr_file}")" != "${want}" || -s ${summary_file} ]]; then
    printf 'FAIL: %s — expected exit 2, stderr %q and no summary; got exit %d, stderr %q\n' \
      "${name}" "${want}" "${actual_exit}" "$(cat -- "${stderr_file}")" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit 2)\n' "${name}"
  fi

  rm --recursive --force -- "${dir}" "${summary_file}" "${stderr_file}" \
    "${stdout_file}" "${outcome_file}"
}

require_locale_gap en_US.UTF-8 || exit 1
run_en_us_scenario 'non-ASCII letter in a NAR hash is malformed under en_US.UTF-8' \
  linpeas_nar_hash 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAé='
run_en_us_scenario 'non-ASCII letter in an image tar hash is malformed under en_US.UTF-8' \
  image_tar_sha256 '000000000000000000000000000000000000000000000000000000000000000é'
run_en_us_scenario 'non-ASCII digit in a manifest digest is malformed under en_US.UTF-8' \
  image_manifest_digest 'sha256:111111111111111111111111111111111111111111111111111111111111111５'

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi

printf '\nall scenarios passed.\n'
