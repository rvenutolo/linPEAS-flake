#!/usr/bin/env bash
# tests/check-cliff-tag-pattern.test.sh
#
# Failure-mode harness for scripts/check-cliff-tag-pattern.sh.
# Mirrors the pattern in tests/check-tag-protection.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-cliff-tag-pattern.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/cliff-tag-pattern"

failures=0

# @description Run the script with a fixture; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES (empty string means no file / missing)
# @arg $3 expected exit code (0 clean, 1 drift, 2 could not run)
# @arg $4 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  CLIFF_TOML_OVERRIDE="${fixture}" \
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
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function main() {
  run_scenario 'correct tag_pattern passes' \
    "${FIXTURES}/good-cliff.toml" 0 ''

  run_scenario 'semver tag_pattern fails' \
    "${FIXTURES}/bad-semver-cliff.toml" 1 'tag_pattern drift in'

  # A config that was never read cannot have drifted: the could-not-run
  # code, not the drift code the absent-key case below carries.
  run_scenario 'missing cliff.toml exits tooling code' \
    '/nonexistent/cliff.toml' 2 'cliff.toml not found'

  run_scenario 'cliff.toml without tag_pattern key fails' \
    "${FIXTURES}/bad-no-key-cliff.toml" 1 'tag_pattern key absent'

  # A config that does not parse is one this check could not read: yq
  # exits 1 on it, and that 1 is the same status a drifted pattern
  # carries, so the read has to be checked rather than trusted.
  # Written at run time rather than kept in the tree: the formatters
  # refuse to touch unparsable TOML.
  local bad_toml_dir
  bad_toml_dir="$(mktemp --directory)"
  printf '[git]\ntag_pattern = "\n' >"${bad_toml_dir}/cliff.toml"
  run_scenario 'unparsable cliff.toml exits tooling code' \
    "${bad_toml_dir}/cliff.toml" 2 'cannot read .git.tag_pattern from'
  rm --recursive --force -- "${bad_toml_dir}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
