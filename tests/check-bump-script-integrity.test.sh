#!/usr/bin/env bash
# tests/check-bump-script-integrity.test.sh
#
# Failure-mode harness for scripts/check-bump-script-integrity.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-bump-script-integrity.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-bump-script-integrity"

failures=0

# @arg $1 scenario name
# @arg $2 fixture basename (under FIXTURES)
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
# @arg $5 expected stdout substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r expected_stdout="$5"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  BUMP_SCRIPT_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

readonly GUARD_SET='guards matched: asset url prefix, digest cross-check, atomic pin write'

function main() {
  # A pass names the file it read. Verifying a stand-in and verifying the
  # bump script the release actually runs are the same verdict, and the
  # scanned path is the only thing that tells them apart. The
  # missing-guard assertions below name the diagnostic, not the bare
  # guard label, because the pass summary lists every guard label too.
  run_scenario 'all guards present passes' \
    'good.sh' 0 '' \
    "tests/fixtures/check-bump-script-integrity/good.sh — ${GUARD_SET}"
  run_scenario 'missing url-prefix guard fails' \
    'bad-no-url-prefix.sh' 1 'missing guard: asset url prefix' ''
  run_scenario 'missing digest cross-check fails' \
    'bad-no-digest.sh' 1 'missing guard: digest cross-check' ''
  run_scenario 'truncating pin write fails' \
    'bad-truncating-write.sh' 1 \
    'missing guard: atomic pin write (truncating redirect into pin file)' ''
  # An unreadable bump script was never scanned, so no guard verdict
  # exists: the could-not-run code, not a missing-guard report.
  run_scenario 'missing bump script could not run' \
    'does-not-exist.sh' 2 'bump script not found' ''

  # Live self-scan: the real bump script must retain all guards.
  local -r live_scope="scripts/bump-linpeas.sh — ${GUARD_SET}"
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if ((actual_exit != 0)); then
    printf 'FAIL: live scripts/bump-linpeas.sh is missing a guard:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${live_scope}" "${stdout_file}"; then
    printf 'FAIL: live self-scan summary missing %q\n' "${live_scope}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live scripts/bump-linpeas.sh retains all guards\n'
  fi
  harness_assert_record 'live bump script self-scan' "${live_scope}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
