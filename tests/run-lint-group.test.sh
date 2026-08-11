#!/usr/bin/env bash
# tests/run-lint-group.test.sh
#
# Failure-mode harness for scripts/run-lint-group.sh. Builds a throwaway
# manifest + stub check scripts in a temp dir, drives the runner via the
# *_OVERRIDE env vars, and asserts exit codes, the summary table, and
# that one failing check does NOT abort the rest of the group.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/run-lint-group.sh"

failures=0

# @arg $1 scenario name
# @arg $2 group arg to pass
# @arg $3 expected exit
# @arg $4 expected stdout substring (empty skips)
function run_scenario() {
  local -r name="$1" group="$2" expected_exit="$3" expected_out="$4"
  local outcome_file out_file step_file work scripts_dir tests_dir manifest
  work="$(mktemp -d)"
  scripts_dir="${work}/scripts"
  tests_dir="${work}/tests"
  manifest="${work}/lint-groups.yml"
  mkdir -p "${scripts_dir}" "${tests_dir}"

  # Every group owns at least one check no other group lists, so a
  # row-plus-status assertion can only match the group it belongs to.
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-aaa.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${scripts_dir}/check-bbb.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-ccc.sh"
  printf '#!/usr/bin/env bash\nexit 1\n' >"${scripts_dir}/check-fff.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"${scripts_dir}/check-zzz.sh"
  chmod +x "${scripts_dir}"/check-*.sh
  # demo-first-fail puts its failing check first, so a zzz row proves the
  # runner kept going instead of aborting on the first failure.
  cat >"${manifest}" <<YAML
demo-all-pass:
  - aaa
  - ccc
demo-one-fail:
  - aaa
  - bbb
demo-first-fail:
  - fff
  - zzz
demo-missing:
  - aaa
  - nope
YAML

  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  local actual_exit=0
  LINT_GROUPS_OVERRIDE="${manifest}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" "${group}" >"${out_file}" 2>&1 || actual_exit=$?
  # The exit code is part of what the run observably did, so it is recorded
  # alongside the streams rather than being checked only below.
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
  elif [[ ${expected_exit} -lt 2 ]] && ! grep --fixed-strings --quiet -- '### ' "${step_file}"; then
    # Config errors (exit 2) bail before the table; only assert the
    # $GITHUB_STEP_SUMMARY write when checks actually ran.
    printf 'FAIL: %s — GITHUB_STEP_SUMMARY missing table header\n' "${name}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --recursive --force -- "${work}" "${outcome_file}" "${out_file}" "${step_file}"
}

# @description Prove a failing check *.test.sh skips its check script and
#              marks the row FAIL (the runner gates each check on its test).
function run_test_gate_scenario() {
  local work scripts_dir tests_dir manifest outcome_file out_file step_file sentinel
  work="$(mktemp -d)"
  scripts_dir="${work}/scripts"
  tests_dir="${work}/tests"
  manifest="${work}/lint-groups.yml"
  sentinel="${work}/ran"
  mkdir -p "${scripts_dir}" "${tests_dir}"
  # The check would pass AND leave a sentinel if it ran...
  printf '#!/usr/bin/env bash\ntouch %q\nexit 0\n' "${sentinel}" >"${scripts_dir}/check-ttt.sh"
  # ...but its test fails, so the runner must skip the check script.
  printf '#!/usr/bin/env bash\nexit 1\n' >"${tests_dir}/check-ttt.test.sh"
  chmod +x "${scripts_dir}"/check-*.sh "${tests_dir}"/check-*.test.sh
  printf 'demo-testfail:\n  - ttt\n' >"${manifest}"

  outcome_file="$(mktemp)"
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  local actual_exit=0
  LINT_GROUPS_OVERRIDE="${manifest}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" demo-testfail >"${out_file}" 2>&1 || actual_exit=$?
  # The exit code is part of what the run observably did, so it is recorded
  # alongside the streams rather than being checked only below.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record 'failing check test skips the check script' \
    '| ttt | FAIL |' "${outcome_file}" "${out_file}" "${step_file}"

  if [[ ${actual_exit} -ne 1 ]]; then
    printf 'FAIL: failing test -> expected exit 1, got %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- '| ttt | FAIL |' "${out_file}"; then
    printf 'FAIL: failing test -> ttt not marked FAIL\n' >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -e ${sentinel} ]]; then
    printf 'FAIL: failing test did not skip the check script (sentinel present)\n' >&2
    failures=$((failures + 1))
  else
    printf 'PASS: failing check test skips the check script and marks it FAIL\n'
  fi
  rm --recursive --force -- "${work}" "${outcome_file}" "${out_file}" "${step_file}"
}

function main() {
  run_scenario 'all checks pass -> exit 0' 'demo-all-pass' 0 '| ccc | pass |'
  run_scenario 'one check fails -> exit 1' 'demo-one-fail' 1 '| bbb | FAIL |'
  # don't-abort: zzz must still appear in the table after fff failed
  run_scenario 'failing check does not abort the rest' 'demo-first-fail' 1 '| zzz | pass |'
  run_scenario 'missing script -> exit 1' 'demo-missing' 1 '| nope | FAIL |'
  run_scenario 'unknown group -> exit 2' 'no-such-group' 2 ''
  run_test_gate_scenario

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
