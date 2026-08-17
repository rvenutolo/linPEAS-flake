#!/usr/bin/env bash
# tests/check-guard-exit-code.test.sh
#
# Failure-mode harness for scripts/check-guard-exit-code.sh.
#
# Each scenario is a miniature scripts/ tree carrying exactly one guard
# shape, so the expected message names the shape under test and nothing
# a sibling scenario also prints.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-guard-exit-code.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/guard-exit-code"

failures=0

# @description Run the lint over one fixture tree; assert exit code and
# the expected output substring.
# @arg $1 scenario name
# @arg $2 fixture subdir (its scripts/ subtree is the scan root)
# @arg $3 expected exit
# @arg $4 expected substring across stdout+stderr (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_msg="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SCRIPTS_DIR_OVERRIDE="${FIXTURES}/${fixture_dir}/scripts" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'output was:\n' >&2
    cat -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" \
      "${stdout_file}" "${stderr_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    printf 'output was:\n' >&2
    cat -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  run_scenario 'tool guard exiting 1 is a hit' \
    'bad-tool-guard' 1 '! command -v yq >/dev/null 2>&1'
  # shellcheck disable=SC2016 # the asserted substring is the fixture's literal guard text
  run_scenario 'input-file guard exiting 1 is a hit' \
    'bad-file-guard' 1 '[[ ! -f ${doc} ]]'
  # Absence mixed with a content predicate under `||` reaches the branch
  # without anything being missing, so the exit stays a drift verdict.
  run_scenario 'compound availability-plus-content test is not a hit' \
    'good-compound-test' 0 '1 script(s) scanned, 0 exemption(s)'
  run_scenario 'rationale-bearing exemption is counted, not flagged' \
    'good-exempted' 0 '1 script(s) scanned, 1 exemption(s)'
  # The marker word appears on the exit line, but only inside a sentence
  # describing the escape hatch — it never opens the comment, so it must
  # not be read as taking the exemption.
  run_scenario 'a marker quoted in prose on the exit line is not an exemption' \
    'bad-prose-marker' 1 'bad-prose-marker/scripts/reads-input.sh:8: exits 1 inside a guard'
  # An empty rationale is its own finding: silently honoring it would
  # make the marker a way to opt out of stating a reason.
  run_scenario 'exemption without a rationale is a hit' \
    'bad-exemption-no-rationale' 1 'marker carries no rationale'
  run_scenario 'guards already exiting 2 pass' \
    'good-clean' 0 '2 script(s) scanned, 0 exemption(s)'
  # The violation sits under lib/ beside a clean top-level script, so a
  # scan that stops at the root still reads a file and reports nothing.
  # The asserted path is what discriminates this from the tool-guard
  # scenario above, whose guard text a shared-library guard repeats.
  run_scenario 'a guard under lib/ is reached by the scan' \
    'bad-lib' 1 'bad-lib/scripts/lib/needs-shfmt.sh:10: exits 1 inside a guard'
  # Nothing to scan is a missing input, not a clean tree — the two must
  # not share an exit code.
  run_scenario 'absent scripts dir is a tooling error' \
    'no-such-fixture' 2 'scripts dir not found'
  # An unguarded temp-file creation is the same class one level down: an
  # unwritable TMPDIR makes the tool exit 1, which the caller reports as
  # a violation of content the run never read.
  run_scenario 'a bare temp-file creation is a hit' \
    'bad-bare-mktemp' 1 'bad-bare-mktemp/scripts/take-temp.sh:8: creates a temp file with a bare mktemp'
  # Each fixture below scans a different number of files so that no two
  # clean scenarios share the summary line, which is their whole output.
  run_scenario 'every guarded-helper form passes' \
    'good-make-temp' 0 '3 script(s) scanned, 0 exemption(s)'
  run_scenario 'rationale-bearing temp-file exemptions are counted' \
    'good-mktemp-exempted' 0 '1 script(s) scanned, 2 exemption(s)'
  run_scenario 'temp-file exemption without a rationale is a hit' \
    'bad-mktemp-no-rationale' 1 'exit-code-exempt marker on a bare mktemp carries no rationale'
  # Command position, not word presence: a whole-line comment, a
  # parenthetical, a trailing comment and a string operand all name the
  # command without running it.
  run_scenario 'prose naming the temp-file command is not a hit' \
    'good-mktemp-prose' 0 '4 script(s) scanned, 0 exemption(s)'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
