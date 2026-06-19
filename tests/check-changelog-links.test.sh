#!/usr/bin/env bash
# tests/check-changelog-links.test.sh
#
# Failure-mode harness for scripts/check-changelog-links.sh.
# Mirrors the pattern in tests/check-cliff-tag-pattern.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-changelog-links.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/changelog-links"

readonly DUP_REGEX='\(\[#([0-9]+)\]\([^)]*\)\) \(\[#\1\]\('

failures=0

# @description Run the script with a fixture; assert exit code and stderr.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES (or absolute path; empty = missing)
# @arg $3 expected exit code
# @arg $4 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  CLIFF_TOML_OVERRIDE="${fixture}" \
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

  rm --force -- "${stderr_file}"
}

# @description Assert the duplicate-link regex against a static line. Proves the
# no-false-positive contract deterministically, independent of git-cliff/history.
# @arg $1 scenario name
# @arg $2 the changelog line to test
# @arg $3 "match" if the regex should fire, "nomatch" otherwise
function run_regex_scenario() {
  local -r name="$1"
  local -r line="$2"
  local -r expectation="$3"

  local hit=0
  printf '%s\n' "${line}" | grep --quiet --perl-regexp "${DUP_REGEX}" || hit=$?

  if [[ ${expectation} == 'match' && ${hit} -ne 0 ]]; then
    printf 'FAIL: %s — regex should match but did not\n' "${name}" >&2
    failures=$((failures + 1))
  elif [[ ${expectation} == 'nomatch' && ${hit} -eq 0 ]]; then
    printf 'FAIL: %s — regex matched but should not (false positive)\n' "${name}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s\n' "${name}"
  fi
}

function main() {
  run_scenario 'current cliff.toml passes' \
    "${FIXTURES}/good-cliff.toml" 0 ''

  run_scenario 'doubled PR-link preprocessor fails' \
    "${FIXTURES}/bad-duplicate-link.toml" 1 'Duplicate identical PR links'

  run_scenario 'missing scorecard preprocessor fails' \
    "${FIXTURES}/bad-no-preprocessor.toml" 1 '15-check allowlist'

  run_scenario 'missing cliff.toml fails' \
    '/nonexistent/cliff.toml' 1 'cliff.toml not found'

  run_regex_scenario 'identical adjacent PR links match' \
    '- ci: thing ([#190](https://x/pull/190)) ([#190](https://x/pull/190))' \
    'match'

  run_regex_scenario 'distinct adjacent PR links do not match' \
    '- ci: thing ([#190](https://x/pull/190)) ([#233](https://x/pull/233))' \
    'nomatch'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
