#!/usr/bin/env bash
# tests/check-payload-source-helper.test.sh
#
# Spec-driven harness for scripts/check-payload-source-helper.sh. Drives
# the lint against fixture scripts/ + tests/ roots via
# SCRIPTS_DIR_OVERRIDE + TESTS_DIR_OVERRIDE, then asserts it holds on the
# live tree.
#
# Every clean scenario asserts a tally rather than a bare exit 0. A lint
# that dies on a file and swallows the status also exits 0, so the exit
# code alone cannot separate "scanned this file and found nothing" from
# "never got through this file at all" — only a count of what was
# examined can.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-payload-source-helper.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-payload-source-helper"

failures=0

# ${1}=scenario name       ${2}=scripts dir  ${3}=tests dir
# ${4}=wanted exit         ${5}=wanted output substring ('' for none)
# ${6}=1 to run with LINT_ALLOW_EMPTY_SCAN set (default: unset)
#
# The substring is looked for across stdout and stderr together: the
# clean verdict is a stdout tally and a finding is a stderr diagnostic,
# and a scenario should not have to know which stream its expectation
# lands on to be able to state it.
function expect() {
  local -r name="$1" scripts_dir="$2" tests_dir="$3" want_exit="$4" want_msg="$5"
  local -r allow_empty="${6:-}"

  local stdout_file stderr_file outcome_file
  stdout_file="$(mktemp)"
  stderr_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local got_exit=0
  LINT_ALLOW_EMPTY_SCAN="${allow_empty}" \
    SCRIPTS_DIR_OVERRIDE="${scripts_dir}" \
    TESTS_DIR_OVERRIDE="${tests_dir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  local got_output
  got_output="$(cat -- "${stdout_file}" "${stderr_file}")"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  output: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_output}" >&2
    failures=$((failures + 1))
  elif [[ -n ${want_msg} && ${got_output} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: output missing %q\n  got: %s\n' \
      "${name}" "${want_msg}" "${got_output}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %s)\n' "${name}" "${got_exit}"
  fi

  rm --force -- "${stdout_file}" "${stderr_file}" "${outcome_file}"
}

function main() {
  # A fixture tree whose tests/ side is deliberately absent points at
  # this name, so the scan set comes from the scripts/ side alone.
  local -r no_tests="${FIXTURES}/tests-does-not-exist"
  local -r no_scripts="${FIXTURES}/scripts-does-not-exist"

  # (a) GOOD: the source is named by the helper, so no assignment writes
  # an override variable's name. Asserted on the whole tally, not on the
  # violation count alone: the count of assignments actually examined is
  # what separates a scan from a skip. This fixture predates the read
  # rule and holds no cat -- capture or helper read at all, so the read
  # tally is legitimately zero and needs the same override (l) below
  # uses for a zero assignment tally.
  expect 'a helper-named source is clean' \
    "${FIXTURES}/clean/scripts" "${no_tests}" 0 \
    '1 file(s) scanned, 2 assignment(s) examined, 0 violation(s), 0 exemption(s) applied, 0 read(s) examined' 1

  # (b) BAD: the hand-inlined conditional, single-quoted — the shape all
  # ten pre-helper copies in this repo were written in.
  expect 'a single-quoted hand-named source is a violation' \
    "${FIXTURES}/inlined/scripts" "${no_tests}" 1 \
    "payload_source='RENOVATE_JSON_OVERRIDE'"

  # (c) BAD: the same rule written as a bare unquoted word. The parser
  # reports this word as a plain literal, a different node shape from
  # (b), so an arm that only reads quoted words misses it entirely.
  expect 'a bare unquoted hand-named source is a violation' \
    "${FIXTURES}/unquoted/scripts" "${no_tests}" 1 \
    "bare_source='RENOVATE_JSON_OVERRIDE'"

  # (d) BAD: and written double-quoted, a third node shape — a quoted
  # word wrapping one literal part.
  expect 'a double-quoted hand-named source is a violation' \
    "${FIXTURES}/double-quoted/scripts" "${no_tests}" 1 \
    "quoted_source='RENOVATE_JSON_OVERRIDE'"

  # (e) GOOD: the same shape as (b) carrying a marker with a rationale.
  # Asserted on the exemption tally rather than on exit 0, so the
  # scenario proves the marker was read and applied rather than that
  # nothing was found. Holds no cat -- capture either, so it needs the
  # same empty-read override (a) does.
  expect 'a declared exemption clears the assignment' \
    "${FIXTURES}/exempt/scripts" "${no_tests}" 0 \
    '0 violation(s), 1 exemption(s) applied, 0 read(s) examined' 1

  # (f) BAD: a marker with no rationale. An exemption nobody has to
  # justify is a way to switch the rule off in place, so the empty
  # marker excuses nothing.
  expect 'a marker with no rationale excuses nothing' \
    "${FIXTURES}/empty-marker/scripts" "${no_tests}" 1 \
    "unmarked_source='RENOVATE_JSON_OVERRIDE'"

  # (g) BAD: a marker on a file already compliant. A stale exemption is
  # drift, not a no-op, and it must be reported on a tree that holds no
  # violation at all — otherwise it survives exactly as long as the rule
  # is being obeyed everywhere else.
  expect 'a marker excusing nothing is a violation' \
    "${FIXTURES}/stale-marker/scripts" "${no_tests}" 1 \
    'carries a payload-source-exempt marker but holds no assignment the rule matches'

  # (h) TOOLING, and the most valuable fixture in this suite: a compliant
  # file that also holds an empty single-quoted assignment. The parser
  # emits no literal text at all for that word, so a detector reading the
  # text unguarded dies on this file — and a lint that swallows that
  # status reports the file clean and exits 0 all the same. The assertion
  # is therefore the assignment tally, which only a completed scan
  # produces. Holds no cat -- capture either, so it needs the same
  # empty-read override (a) does.
  expect 'an empty single-quoted assignment is scanned, not skipped' \
    "${FIXTURES}/empty-quote/scripts" "${no_tests}" 0 \
    '1 file(s) scanned, 3 assignment(s) examined, 0 violation(s), 0 exemption(s) applied, 0 read(s) examined' 1

  # (i) BREADTH: the banned shape inside scripts/lib/. The helper this
  # rule points at lives there, so a scan that stops at the top level
  # cannot see the neighbors most likely to copy it.
  expect 'a hand-named source under scripts/lib is a violation' \
    "${FIXTURES}/lib-reach/scripts" "${no_tests}" 1 \
    "lib_source='RENOVATE_JSON_OVERRIDE'"

  # (j) BREADTH: the banned shape inside a harness. A harness names the
  # source it expects a script to report, so the same copy lands there.
  expect 'a hand-named source under tests is a violation' \
    "${no_scripts}" "${FIXTURES}/tests-reach/tests" 1 \
    "harness_source='RENOVATE_JSON_OVERRIDE'"

  # (k) TOOLING: a scan root whose files hold no assignment at all. A
  # clean verdict here would be indistinguishable from a detector that
  # stopped reaching assignments altogether.
  expect 'zero assignments is a could-not-run' \
    "${FIXTURES}/no-assignments/scripts" "${no_tests}" 2 \
    'examined 0 assignment(s)'

  # (l) TOOLING: ...and the documented override suppresses it, for a scan
  # root that deliberately holds none.
  expect 'zero assignments passes when allowed' \
    "${FIXTURES}/no-assignments/scripts" "${no_tests}" 0 \
    '1 file(s) scanned, 0 assignment(s) examined, 0 violation(s), 0 exemption(s) applied' 1

  # --- the read rule -------------------------------------------------------

  # (n) GOOD: the payload is read through the library helper, so no
  # cat -- capture appears in this file for the rule to examine.
  expect 'a helper-read payload is clean' \
    "${FIXTURES}/read-clean/scripts" "${no_tests}" 0 \
    '1 file(s) scanned, 3 assignment(s) examined, 0 violation(s), 0 exemption(s) applied, 1 read(s) examined'

  # (o) BAD: a hand-rolled cat -- capture, gated the way a real payload
  # read would be. The rule does not require the dataflow proof that the
  # captured variable actually reaches a gate — the capture alone is the
  # violation, since a fetch wrapped in its own function shares no
  # variable name with the gate for a dataflow check to follow.
  # shellcheck disable=SC2016 # literal fixture text, not a shell expansion
  expect 'a hand-rolled cat -- read is a violation' \
    "${FIXTURES}/read-inlined/scripts" "${no_tests}" 1 \
    'cat -- "${payload_path}" hand-reads a payload'

  # (p) GOOD: the same shape as (o), excused by a marker carrying a
  # rationale. Asserted on the exemption tally and the read tally
  # together, so the scenario proves the marker was read and applied
  # rather than that the capture went unexamined.
  expect 'a declared read exemption clears the capture' \
    "${FIXTURES}/read-exempt/scripts" "${no_tests}" 0 \
    '3 assignment(s) examined, 0 violation(s), 1 exemption(s) applied, 1 read(s) examined'

  # (q) BAD: a marker with no rationale. The same "empty exemption is
  # drift" rule the source-naming marker enforces applies here too.
  # shellcheck disable=SC2016 # literal fixture text, not a shell expansion
  expect 'a read marker with no rationale excuses nothing' \
    "${FIXTURES}/read-empty-marker/scripts" "${no_tests}" 1 \
    'cat -- "${payload_path}" hand-reads a payload'

  # (r) BAD: a marker on a file that already reads through the helper.
  # The file holds no capture the rule matches, so the marker is drift
  # and is reported before any violation would be.
  expect 'a read marker excusing nothing is a violation' \
    "${FIXTURES}/read-stale-marker/scripts" "${no_tests}" 1 \
    'carries a payload-read-exempt marker but holds no hand-rolled read the rule matches'

  # (s) GOOD: a cat -- capture of a temp file this same script created.
  # The automatic temp exemption needs no marker — a script tearing down
  # its own scratch file is not the shape this rule polices.
  expect 'a read of a self-created temp is clean' \
    "${FIXTURES}/read-temp/scripts" "${no_tests}" 0 \
    '2 assignment(s) examined, 0 violation(s), 0 exemption(s) applied, 1 read(s) examined'

  # (u) GOOD: a read of a self-created temp whose `cat` carries an
  # option ahead of the `--` separator. The path operand is the word
  # after `--`, wherever that lands, so a detector reading a fixed
  # argument position sees the separator instead of the variable, finds
  # no variable to trace, and reports a temp the script created itself.
  # The fixture carries one assignment more than (n) and two more than
  # (s), so its clean tally is its own rather than a repeat of theirs.
  expect 'a flagged read of a self-created temp is clean' \
    "${FIXTURES}/read-flagged-temp/scripts" "${no_tests}" 0 \
    '4 assignment(s) examined, 0 violation(s), 0 exemption(s) applied, 1 read(s) examined'

  # (v) BAD: the same option-before-`--` shape reading a payload path.
  # The report has to name that path operand; a report naming `--` tells
  # a maintainer nothing about which read to convert.
  # shellcheck disable=SC2016 # literal fixture text, not a shell expansion
  expect 'a flagged hand-rolled read names the path, not the separator' \
    "${FIXTURES}/read-flagged-payload/scripts" "${no_tests}" 1 \
    'cat -- "${payload_path}" hand-reads a payload'

  # (t) LIVE: the real tree must satisfy both rules — zero violations,
  # every hand-rolled read either converted or carrying a
  # `payload-read-exempt` marker with a rationale. The exit code alone
  # cannot tell a scan that reached the whole tree apart from one that
  # silently stopped early, so the assertion also covers the breadth
  # counts themselves — nonzero assignments and nonzero reads examined
  # — rather than a substring lifted from today's file count, which
  # would pin this scenario to a moving target as the tree grows.
  local live_out_file live_outcome_file live_exit live_assignments live_reads
  live_out_file="$(mktemp)"
  live_outcome_file="$(mktemp)"
  live_exit=0
  "${SCRIPT}" >"${live_out_file}" 2>&1 || live_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${live_exit}" >"${live_outcome_file}"
  harness_assert_record 'the live tree is clean' '' "${live_outcome_file}" "${live_out_file}"
  if [[ ${live_exit} -ne 0 ]]; then
    printf 'FAIL: the live tree is clean — expected exit 0, got %d\n' "${live_exit}" >&2
    cat -- "${live_out_file}" >&2
    failures=$((failures + 1))
  else
    live_assignments="$(grep -oE '[0-9]+ assignment\(s\) examined' "${live_out_file}" | grep -oE '^[0-9]+' || true)"
    live_reads="$(grep -oE '[0-9]+ read\(s\) examined' "${live_out_file}" | grep -oE '^[0-9]+' || true)"
    if [[ -z ${live_assignments} || ${live_assignments} -eq 0 ]]; then
      printf 'FAIL: the live tree is clean — 0 assignments examined\n' >&2
      cat -- "${live_out_file}" >&2
      failures=$((failures + 1))
    elif [[ -z ${live_reads} || ${live_reads} -eq 0 ]]; then
      printf 'FAIL: the live tree is clean — 0 reads examined\n' >&2
      cat -- "${live_out_file}" >&2
      failures=$((failures + 1))
    else
      printf 'PASS: the live tree is clean (exit 0, %d assignment(s) examined, %d read(s) examined)\n' \
        "${live_assignments}" "${live_reads}"
    fi
  fi
  rm --force -- "${live_out_file}" "${live_outcome_file}"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
