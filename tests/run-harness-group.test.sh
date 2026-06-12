#!/usr/bin/env bash
# tests/run-harness-group.test.sh
#
# Failure-mode harness for scripts/run-harness-group.sh. Seeds stub
# test harnesses + enforce scripts under temp dirs, drives the runner
# via TESTS_DIR_OVERRIDE + SCRIPTS_DIR_OVERRIDE, and asserts: exit
# codes, the summary table + $GITHUB_STEP_SUMMARY write, that one
# failing harness does not abort the rest, that the enforce-tagged
# harness DOES run its live script, that test-only harnesses do NOT
# run a same-named script, and that enforce is skipped when the test
# itself fails.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/run-harness-group.sh"

failures=0

# @arg $1 path  @arg $2 exit code  @arg $3 optional marker file to touch
function make_stub() {
  local -r path="$1" code="$2" marker="${3:-}"
  {
    printf '#!/usr/bin/env bash\n'
    [[ -n ${marker} ]] && printf 'touch %q\n' "${marker}"
    printf 'exit %s\n' "${code}"
  } >"${path}"
  chmod +x "${path}"
}

# Drives one scenario. Caller pre-builds $tests_dir and $scripts_dir.
# @arg $1 name  @arg $2 tests_dir  @arg $3 scripts_dir
# @arg $4 expected exit  @arg $5 expected stdout substring (empty skips)
# @arg $6 forbidden marker path for allowed-actions enforce (empty skips)
# @arg $7 forbidden marker path for settings-posture enforce (empty skips)
# @arg $8 forbidden marker path for ratchet enforce (empty skips)
function run_scenario() {
  local -r name="$1" tests_dir="$2" scripts_dir="$3"
  local -r expected_exit="$4" expected_out="$5"
  local -r forbidden_allowed="${6:-}" forbidden_settings="${7:-}" forbidden_ratchet="${8:-}"
  local out_file step_file actual_exit=0
  out_file="$(mktemp)"
  step_file="$(mktemp)"
  TESTS_DIR_OVERRIDE="${tests_dir}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    GITHUB_STEP_SUMMARY="${step_file}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?

  local failed_check=''
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    failed_check="expected exit ${expected_exit}, got ${actual_exit}"
  elif [[ -n ${expected_out} ]] && ! grep --fixed-strings --quiet -- "${expected_out}" "${out_file}"; then
    failed_check="stdout missing '${expected_out}'"
  elif ! grep --fixed-strings --quiet -- '### harness-group' "${step_file}"; then
    failed_check='GITHUB_STEP_SUMMARY missing table header'
  elif [[ -n ${forbidden_allowed} && -e ${forbidden_allowed} ]]; then
    failed_check='allowed-actions-api harness wrongly ran its enforce script'
  elif [[ -n ${forbidden_settings} && -e ${forbidden_settings} ]]; then
    failed_check='settings-posture harness wrongly ran its enforce script'
  elif [[ -n ${forbidden_ratchet} && -e ${forbidden_ratchet} ]]; then
    failed_check='ratchet enforce ran despite test failure'
  fi

  if [[ -n ${failed_check} ]]; then
    printf 'FAIL: %s — %s\n' "${name}" "${failed_check}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --force -- "${out_file}" "${step_file}"
}

# Seeds the three exact harness names. Exit codes per component are passed
# in; the allowed-actions and settings-posture enforce stubs (which the
# runner must never call for test-only harnesses) touch their respective
# forbidden markers when run.
# @arg $1 work dir  @arg $2 ratchet-test  $3 ratchet-enforce exit code
#      $4 allowed-test  $5 settings-test
#      $6 allowed forbidden-marker  $7 settings forbidden-marker
#      $8 ratchet-enforce forbidden-marker (optional)
function seed() {
  local -r work="$1"
  local -r tests_dir="${work}/tests" scripts_dir="${work}/scripts"
  mkdir -p "${tests_dir}" "${scripts_dir}"
  make_stub "${tests_dir}/check-ratchet-pin-audit.test.sh" "$2"
  make_stub "${scripts_dir}/check-ratchet-pin-audit.sh" "$3" "${8:-}"
  make_stub "${tests_dir}/check-allowed-actions-api.test.sh" "$4"
  make_stub "${tests_dir}/check-settings-posture.test.sh" "$5"
  # Same-named enforce stubs the runner must NOT run for test-only harnesses.
  make_stub "${scripts_dir}/check-allowed-actions-api.sh" 0 "$6"
  make_stub "${scripts_dir}/check-settings-posture.sh" 0 "$7"
}

function main() {
  local work forbidden_allowed forbidden_settings

  # Scenario 1: all pass.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 0 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'all harnesses pass -> exit 0' \
    "${work}/tests" "${work}/scripts" 0 '| ratchet-pin-audit | pass |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 2: one harness fails, others still run.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 1 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'settings-posture test fails -> exit 1' \
    "${work}/tests" "${work}/scripts" 1 '| settings-posture | FAIL |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 0 0 1 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'failing harness does not abort the rest' \
    "${work}/tests" "${work}/scripts" 1 '| allowed-actions-api | pass |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 3: ratchet test passes but its enforce script fails ->
  # row FAIL, proving the enforce script ran.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  seed "${work}" 0 1 0 0 "${forbidden_allowed}" "${forbidden_settings}"
  run_scenario 'ratchet enforce script runs and can fail the row' \
    "${work}/tests" "${work}/scripts" 1 '| ratchet-pin-audit | FAIL |' \
    "${forbidden_allowed}" "${forbidden_settings}"
  rm --recursive --force -- "${work}"

  # Scenario 4: ratchet TEST fails -> enforce must NOT run.
  work="$(mktemp -d)"
  forbidden_allowed="${work}/ran-allowed"
  forbidden_settings="${work}/ran-settings"
  local forbidden_ratchet="${work}/ran-ratchet-enforce"
  seed "${work}" 1 0 0 0 "${forbidden_allowed}" "${forbidden_settings}" "${forbidden_ratchet}"
  run_scenario 'ratchet test fails -> enforce skipped, row FAIL' \
    "${work}/tests" "${work}/scripts" 1 '| ratchet-pin-audit | FAIL |' \
    "${forbidden_allowed}" "${forbidden_settings}" "${forbidden_ratchet}"
  rm --recursive --force -- "${work}"

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
