#!/usr/bin/env bash
# tests/run-doc-freshness.test.sh
#
# Failure-mode harness for scripts/run-doc-freshness.sh. Builds stub
# refresh-*.test.sh harnesses in a temp dir, drives the runner via
# TESTS_DIR_OVERRIDE, and asserts exit codes, the summary table, and
# that one failing harness does NOT abort the rest.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/run-doc-freshness.sh"

failures=0

# Each mode builds a stub set whose table rows are unique to that mode, so a
# row-plus-status assertion can only match the run it belongs to.
# @arg $1 scenario name
# @arg $2 tests-dir setup mode: all-pass | one-fail | first-fail | empty
# @arg $3 expected exit
# @arg $4 expected stdout substring (empty skips)
function run_scenario() {
  local -r name="$1" mode="$2" expected_exit="$3" expected_out="$4"
  local work tests_dir out_file step_file outcome_file
  work="$(mktemp -d)"
  tests_dir="${work}/tests"
  mkdir -p "${tests_dir}"

  case "${mode}" in
  all-pass | one-fail)
    printf '#!/usr/bin/env bash\nexit 0\n' >"${tests_dir}/refresh-aaa.test.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${tests_dir}/refresh-ccc.test.sh"
    # bbb is the only difference between the two modes: it passes under
    # all-pass and fails under one-fail, so its row isolates the axis.
    if [[ ${mode} == one-fail ]]; then
      printf '#!/usr/bin/env bash\nexit 1\n' >"${tests_dir}/refresh-bbb.test.sh"
    else
      printf '#!/usr/bin/env bash\nexit 0\n' >"${tests_dir}/refresh-bbb.test.sh"
    fi
    ;;
  first-fail)
    # The failing harness sorts first, so a zzz row proves the runner kept
    # going instead of aborting on the first failure.
    printf '#!/usr/bin/env bash\nexit 1\n' >"${tests_dir}/refresh-aaa.test.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${tests_dir}/refresh-zzz.test.sh"
    ;;
  esac
  if [[ ${mode} != empty ]]; then
    chmod +x "${tests_dir}"/refresh-*.test.sh
  fi

  out_file="$(mktemp)"
  step_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  TESTS_DIR_OVERRIDE="${tests_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  # The record is the whole observable outcome. Both streams already land in
  # one file here, so the record is the exit code, that combined stream, and
  # the step summary the runner wrote.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_out}" \
    "${outcome_file}" "${out_file}" "${step_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_out} ]] && ! grep --fixed-strings --quiet -- "${expected_out}" "${out_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_out}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${expected_exit} -lt 2 ]] && ! grep --fixed-strings --quiet -- '### doc-freshness' "${step_file}"; then
    # Config errors (exit 2) bail before the table; only assert the
    # $GITHUB_STEP_SUMMARY write when harnesses actually ran.
    printf 'FAIL: %s — GITHUB_STEP_SUMMARY missing table header\n' "${name}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --recursive --force -- "${work}" "${out_file}" "${step_file}" "${outcome_file}"
}

function main() {
  run_scenario 'all harnesses pass -> exit 0' 'all-pass' 0 '| refresh-bbb.test.sh | pass |'
  run_scenario 'one harness fails -> exit 1' 'one-fail' 1 '| refresh-bbb.test.sh | FAIL |'
  # don't-abort: zzz must still appear in the table after aaa failed
  run_scenario 'failing harness does not abort the rest' 'first-fail' 1 '| refresh-zzz.test.sh | pass |'
  run_scenario 'empty set -> exit 2' 'empty' 2 ''

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
