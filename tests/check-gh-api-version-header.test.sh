#!/usr/bin/env bash
# tests/check-gh-api-version-header.test.sh
#
# Failure-mode harness for scripts/check-gh-api-version-header.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-gh-api-version-header.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-gh-api-version-header"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
# @arg $5 expected stdout substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r expected_stdout="$5"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture_dir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
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
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  # The clean path states its scope: how many call sites were held to the
  # header rule, and how many API mentions were set aside as comments. A
  # run that verified two live calls and a run that verified none because
  # every mention sat in a comment are the same verdict but very
  # different facts, and only the summary separates them.
  run_scenario 'gh api with explicit header passes' \
    'good' 0 '' \
    'scanned 1 script(s); 2 API call site(s) carry an explicit header; 1 comment mention(s) skipped'
  run_scenario 'bare gh api fails' \
    'bad-no-header' 1 'missing X-GitHub-Api-Version' ''
  run_scenario 'gh api on continuation lines fails' \
    'bad-continuation' 1 'missing X-GitHub-Api-Version' ''
  run_scenario 'gh api in comments only passes' \
    'good-comment-only' 0 '' \
    'scanned 1 script(s); 0 API call site(s) carry an explicit header; 3 comment mention(s) skipped'
  run_scenario 'api.github.com request without header fails' \
    'bad-apigithub' 1 'missing X-GitHub-Api-Version' ''
  # A directory that is not there was never scanned, so it holds no
  # offenders: the could-not-run code, not a violation report.
  run_scenario 'missing scripts dir could not run' \
    'does-not-exist' 2 'scripts dir not found' ''

  # Self-scan: the live scripts/ dir must lint clean. Guards against
  # any future script regressing on the X-GitHub-Api-Version header.
  # Only the live tree holds this checker itself, so the self-exclusion
  # clause is what marks the summary as covering the real scripts/ dir;
  # the counts around it grow with the repo and are not asserted.
  local -r live_scope='self-excluded: check-gh-api-version-header.sh'
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if ((actual_exit != 0)); then
    printf 'FAIL: live scripts/ has offenders:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${live_scope}" "${stdout_file}"; then
    printf 'FAIL: live scripts/ summary missing %q\n' "${live_scope}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live scripts/ clean\n'
  fi
  harness_assert_record 'live scripts/ self-scan' "${live_scope}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
