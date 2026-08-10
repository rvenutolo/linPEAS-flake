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
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture_dir}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

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
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" "${stderr_file}"
  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'gh api with explicit header passes' \
    'good' 0 ''
  run_scenario 'bare gh api fails' \
    'bad-no-header' 1 'missing X-GitHub-Api-Version'
  run_scenario 'gh api on continuation lines fails' \
    'bad-continuation' 1 'missing X-GitHub-Api-Version'
  run_scenario 'gh api in comments only passes' \
    'good-comment-only' 0 ''
  run_scenario 'api.github.com request without header fails' \
    'bad-apigithub' 1 'missing X-GitHub-Api-Version'

  # Self-scan: the live scripts/ dir must lint clean. Guards against
  # any future script regressing on the X-GitHub-Api-Version header.
  local stderr_file
  stderr_file="$(mktemp)"
  local actual_exit=0
  "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  if ((actual_exit != 0)); then
    printf 'FAIL: live scripts/ has offenders:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live scripts/ clean\n'
  fi
  harness_assert_record 'live scripts/ self-scan' '' "${stderr_file}"
  rm --force -- "${stderr_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
