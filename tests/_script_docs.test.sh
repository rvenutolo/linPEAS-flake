#!/usr/bin/env bash
# tests/_script_docs.test.sh
# @subject scripts/_script_docs.awk
#
# Spec-driven unit test for scripts/_script_docs.awk.
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly PARSER="${REPO_ROOT}/scripts/_script_docs.awk"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/refresh-scripts-reference"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() {
  printf 'PASS: %s\n' "$1"
}

function test_full_matches_expected() {
  local -r name='full.sh parses to expected JSON'
  local actual sorted_actual sorted_expected
  actual="$(awk --file "${PARSER}" <"${FIXTURES}/full.sh")"
  sorted_actual="$(printf '%s\n' "${actual}" | jq --sort-keys '.')"
  sorted_expected="$(jq --sort-keys '.' <"${FIXTURES}/expected-full.json")"
  if diff <(printf '%s\n' "${sorted_expected}") \
    <(printf '%s\n' "${sorted_actual}") >/dev/null; then
    pass "${name}"
  else
    fail "${name}"
    diff <(printf '%s\n' "${sorted_expected}") \
      <(printf '%s\n' "${sorted_actual}") >&2 || true
  fi
}

function test_no_description_exits_2() {
  local -r name='no-description.sh exits 2 with stderr "missing @description"'
  local outcome_file stdout_file stderr_file actual_exit=0
  outcome_file="$(mktemp)"
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  awk --file "${PARSER}" <"${FIXTURES}/no-description.sh" \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  # The exit code is part of what the run observably did, so it is recorded
  # alongside the streams rather than being checked only below.
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'missing @description' \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ ${actual_exit} -ne 2 ]]; then
    fail "${name} — expected exit 2, got ${actual_exit}"
    cat -- "${stderr_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'missing @description' \
    "${stderr_file}"; then
    fail "${name} — stderr missing phrase"
    cat -- "${stderr_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function test_function_body_description_ignored() {
  # full.sh contains a `# @description` inside a function body. The parser
  # must NOT pick it up — the description should come from the file header.
  local -r name='function-body @description is ignored'
  local actual desc
  actual="$(awk --file "${PARSER}" <"${FIXTURES}/full.sh")"
  desc="$(printf '%s\n' "${actual}" | jq --raw-output '.description')"
  if [[ ${desc} == *'function-level annotation'* ]]; then
    fail "${name} — parser leaked function-body description: ${desc}"
  else
    pass "${name}"
  fi
}

# A tag this repo requires must not be one the parser calls unknown, and a
# tag nothing defines must still be reported. Both halves matter: recognizing
# the declarations by widening the unknown-tag arm itself would silence real
# typos too.
function test_generates_tags_recognized_but_bogus_still_warns() {
  local -r name='@generates declarations are silent; an undefined tag still warns'
  local declared_stderr bogus_stderr stderr_file
  stderr_file="$(make_temp)"
  declared_stderr="$(printf '%s\n' '#!/usr/bin/env bash' '# @description x' \
    '# @generates docs/a.md' '# @generates-block README.md' 'true' |
    awk --file "${PARSER}" 2>&1 >/dev/null)"
  bogus_stderr="$(printf '%s\n' '#!/usr/bin/env bash' '# @description x' \
    '# @bogus y' 'true' | awk --file "${PARSER}" 2>&1 >/dev/null)"
  printf 'declared-tags-stderr: %s\nundefined-tag-stderr: %s\n' \
    "${declared_stderr}" "${bogus_stderr}" >"${stderr_file}"
  harness_assert_record "${name}" 'unknown tag @bogus' "${stderr_file}"
  if [[ -n ${declared_stderr} ]]; then
    fail "${name} — declaration tags warned: ${declared_stderr}"
  elif [[ ${bogus_stderr} != *"unknown tag @bogus"* ]]; then
    fail "${name} — undefined tag no longer reported: ${bogus_stderr}"
  else
    pass "${name}"
  fi
}

function main() {
  test_full_matches_expected
  test_no_description_exits_2
  test_function_body_description_ignored
  test_generates_tags_recognized_but_bogus_still_warns
  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall passed\n'
}

main "$@"
