#!/usr/bin/env bash
# tests/compare-repro.test.sh
#
# Failure-mode harness for scripts/compare-repro.sh.
# Mirrors tests/check-protect-main.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
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

  local summary_file
  summary_file="$(mktemp)"

  local actual_exit=0
  GITHUB_STEP_SUMMARY="${summary_file}" \
    "${SCRIPT}" \
    "${FIXTURES}/${fixture_dir}/build-a.json" \
    "${FIXTURES}/${fixture_dir}/build-b.json" \
    >/dev/null 2>&1 || actual_exit=$?

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

run_scenario \
  'match: identical hashes → exit 0, summary contains MATCH' \
  'match' \
  0 \
  'MATCH'

run_scenario \
  'mismatch-store: differing linpeas_nar_hash → exit 1, summary names field' \
  'mismatch-store' \
  1 \
  'linpeas_nar_hash'

run_scenario \
  'mismatch-image: differing image_tar_sha256 → exit 1, summary names field' \
  'mismatch-image' \
  1 \
  'image_tar_sha256'

run_scenario \
  'mismatch: runbook link present in summary' \
  'mismatch-store' \
  1 \
  'docs/runbooks/reproducibility-check.md'

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d scenario(s) failed.\n' "${failures}" >&2
  exit 1
fi

printf '\nall scenarios passed.\n'
