#!/usr/bin/env bash
# tests/check-flake-lock-provenance.test.sh
#
# Failure-mode harness for scripts/check-flake-lock-provenance.sh.
# Drives the check entirely off fixture files via the BASE_LOCK_FILE /
# HEAD_LOCK_FILE env overrides, so no git history is touched.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-flake-lock-provenance.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-flake-lock-provenance"

# Every scenario runs under a wall-clock bound. The check resolves
# `follows` refs, and an unbounded resolver turns a small crafted lock
# into minutes of CPU; without this the suite would hang instead of
# reporting which fixture is slow. `timeout` reports 124 on a kill, so a
# blown bound surfaces as an exit-code mismatch naming the scenario.
readonly SCENARIO_TIMEOUT_SECS=20

failures=0

# @arg $1 scenario name  @arg $2 base fixture  @arg $3 head fixture
# @arg $4 expected exit  @arg $5 expected output substring (empty skips)
function run_pair_scenario() {
  local -r name="$1" base="$2" head="$3" expected_exit="$4" expected_msg="$5"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/${base}" \
    HEAD_LOCK_FILE="${FIXTURES}/${head}" \
    timeout "${SCENARIO_TIMEOUT_SECS}" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -eq 124 && ${expected_exit} -ne 124 ]]; then
    printf 'FAIL: %s — killed after %ds; the check did not finish\n' \
      "${name}" "${SCENARIO_TIMEOUT_SECS}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_msg}" "${outcome_file}" "${out_file}"
  rm --force -- "${outcome_file}" "${out_file}"
}

# @arg $1 scenario name  @arg $2 head fixture basename  @arg $3 expected exit
# @arg $4 expected stderr/stdout substring (empty skips)
# Thin wrapper over run_pair_scenario anchored at the default base lock.
function run_scenario() {
  local -r name="$1" head="$2" expected_exit="$3" expected_msg="$4"
  run_pair_scenario "${name}" 'base.lock' "${head}" "${expected_exit}" "${expected_msg}"
}

# @arg $1 scenario name  @arg $2 head fixture  @arg $3 expected exit
# @arg $4 expected output substring (empty skips)
# Thin wrapper over run_pair_scenario anchored at the follows-shaped base lock.
function run_follows_scenario() {
  local -r name="$1" head="$2" expected_exit="$3" expected_msg="$4"
  run_pair_scenario "${name}" 'base-follows.lock' "${head}" "${expected_exit}" "${expected_msg}"
}

# Points one of BASE_LOCK_FILE / HEAD_LOCK_FILE at a caller-supplied
# payload path while the other keeps the valid default fixture, so a
# scenario proves the could-not-run path fires on the override under
# test and nowhere else. Shared by the absent, unreadable, and
# directory-payload scenarios below — each supplies a different kind of
# broken path and lets this function drive the script and assert the
# outcome.
# @arg $1 scenario name  @arg $2 override var (BASE_LOCK_FILE or HEAD_LOCK_FILE)
# @arg $3 payload path to use for that var  @arg $4 expected exit
# @arg $5 expected output substring (empty skips)
function run_broken_lock_scenario() {
  local -r name="$1" var="$2" payload="$3" expected_exit="$4" expected_msg="$5"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local base_lock="${FIXTURES}/base.lock" head_lock="${FIXTURES}/base.lock"
  case "${var}" in
  BASE_LOCK_FILE) base_lock="${payload}" ;;
  HEAD_LOCK_FILE) head_lock="${payload}" ;;
  esac
  local actual_exit=0
  BASE_LOCK_FILE="${base_lock}" \
    HEAD_LOCK_FILE="${head_lock}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_msg}" "${outcome_file}" "${out_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --force -- "${outcome_file}" "${out_file}"
}

# @arg $1 scenario name  @arg $2 override var  @arg $3 expected output substring
function run_absent_lock_scenario() {
  local -r name="$1" var="$2" expected_msg="$3"
  run_broken_lock_scenario "${name}" "${var}" "${FIXTURES}/does-not-exist.lock" 2 "${expected_msg}"
}

# Mode bits are no lever for root, so this scenario self-skips there —
# the directory scenario below covers the same could-not-run path for
# every user including root.
# @arg $1 scenario name  @arg $2 override var  @arg $3 expected output substring
function run_unreadable_lock_scenario() {
  local -r name="$1" var="$2" expected_msg="$3"
  if [[ ${EUID} -eq 0 ]]; then
    printf 'SKIP: %s (running as root — mode bits are no lever)\n' "${name}"
    return 0
  fi
  local payload
  payload="$(mktemp)"
  printf '{}' >"${payload}"
  chmod 000 -- "${payload}"
  run_broken_lock_scenario "${name}" "${var}" "${payload}" 2 "${expected_msg}"
  chmod 600 -- "${payload}"
  rm --force -- "${payload}"
}

# @arg $1 scenario name  @arg $2 override var  @arg $3 expected output substring
function run_directory_lock_scenario() {
  local -r name="$1" var="$2" expected_msg="$3"
  local payload
  payload="$(mktemp --directory)"
  run_broken_lock_scenario "${name}" "${var}" "${payload}" 2 "${expected_msg}"
  rm --recursive --force -- "${payload}"
}

function main() {
  # Every clean scenario asserts the whole summary line rather than the bare
  # `provenance OK`. The eight of them resolve different graphs — different
  # entry-point ids, follows depths, and tolerated transitive churn — and the
  # verdict alone renders all of that as the same observable outcome.
  run_scenario 'routine bump passes' 'head-routine.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed'
  run_scenario 'top-level owner change fails' 'head-toplevel-owner.lock' 1 \
    'FAIL: node repointed: alpha (original.owner: orgA -> evil)'
  run_scenario 'top-level type change fails' 'head-toplevel-type.lock' 1 \
    'FAIL: node repointed: alpha (locked.type: github -> git)'
  run_scenario 'top-level input added fails' 'head-toplevel-added.lock' 1 'FAIL: top-level input added: delta'
  run_scenario 'top-level input removed fails' 'head-toplevel-removed.lock' 1 'FAIL: top-level input removed: beta'
  run_scenario 'transitive repoint fails' 'head-transitive-repoint.lock' 1 'FAIL: node repointed: gamma'
  run_scenario 'transitive node added tolerated' 'head-transitive-added.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 1 added, 0 removed'
  run_scenario 'transitive node removed tolerated' 'head-transitive-removed.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 2; transitive churn tolerated: 0 added, 1 removed'
  run_scenario 'garbage head json errors' 'head-garbage.lock' 2 ''
  run_scenario 'top-level rename same source' 'head-toplevel-renamed-same.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 2; transitive churn tolerated: 1 added, 1 removed'
  run_scenario 'top-level rename + repoint fails' 'head-toplevel-renamed-repoint.lock' 1 \
    'FAIL: top-level input repointed: alpha (alpha -> alpha_2)'
  # The absent case keeps exiting 2; the sentence changed from a
  # path-interpolated message (`BASE_LOCK_FILE not found: <resolved
  # path>`) to the canonical could-not-run sentence naming the payload
  # by kind — the override variable's own name, never the fixture path
  # a harness scenario happens to point it at.
  run_absent_lock_scenario 'missing base errors' BASE_LOCK_FILE \
    'payload from BASE_LOCK_FILE not found'
  run_absent_lock_scenario 'missing head errors' HEAD_LOCK_FILE \
    'payload from HEAD_LOCK_FILE not found'
  # This is the reported defect: an unreadable payload dies under the
  # raw `cat` failure at exit 1 — the same code this script uses for a
  # genuine provenance violation.
  run_unreadable_lock_scenario 'unreadable base is a tooling error, not a violation' \
    BASE_LOCK_FILE 'payload from BASE_LOCK_FILE is not readable'
  run_unreadable_lock_scenario 'unreadable head is a tooling error, not a violation' \
    HEAD_LOCK_FILE 'payload from HEAD_LOCK_FILE is not readable'
  # A directory passes the `-f` guard's existence check but fails the
  # read; the guard's "not found" message does not distinguish that
  # from a genuinely absent path.
  run_directory_lock_scenario 'directory-payload base is a tooling error, not a violation' \
    BASE_LOCK_FILE 'payload from BASE_LOCK_FILE could not be read'
  run_directory_lock_scenario 'directory-payload head is a tooling error, not a violation' \
    HEAD_LOCK_FILE 'payload from HEAD_LOCK_FILE could not be read'

  run_follows_scenario 'follows routine bump passes' 'head-follows-routine.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 4 (1 via follows, max depth 1); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed'
  run_follows_scenario 'string-to-array repoint fails' 'head-follows-string-to-array.lock' 1 'FAIL: top-level input repointed: gamma'
  run_follows_scenario 'array-to-array repoint fails' 'head-follows-array-change.lock' 1 'FAIL: top-level input repointed: beta'
  run_follows_scenario 'string-to-array same source passes' 'head-follows-string-to-array-same.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 4 (2 via follows, max depth 1); shared nodes compared: 2; transitive churn tolerated: 0 added, 1 removed'
  run_follows_scenario 'dangling follows path fails' 'head-follows-dangling.lock' 1 \
    'FAIL: top-level input unresolvable (follows path names no such node): beta'
  run_follows_scenario 'cyclic follows fails' 'head-follows-cycle.lock' 1 \
    'FAIL: top-level input unresolvable (follows path exceeds nesting ceiling): beta'

  # Each `bN` input is a two-element path through `bN+1`, so a naive
  # resolver that re-walks every element costs 2^N for a lock under 1 KiB.
  # The step budget must stop it well inside the scenario timeout.
  run_pair_scenario 'branching follows exhausts step budget' \
    'base-follows-branching.lock' 'base-follows-branching.lock' 1 \
    'FAIL: top-level input unresolvable (follows step budget exhausted): b1'
  # A legal chain sitting exactly at the nesting ceiling: bounding total
  # work must not shorten how deep a legitimate `follows` chain may go. The
  # reported max depth is the evidence, and it is what tells an operator how
  # much headroom the ceiling still has.
  run_pair_scenario 'deep legal follows chain resolves' \
    'base-follows-deep.lock' 'base-follows-deep.lock' 0 \
    'provenance OK: entry "root"; top-level inputs resolved: 33 (32 via follows, max depth 32); shared nodes compared: 1; transitive churn tolerated: 0 added, 0 removed'

  run_scenario 'decoy renamed root fails' 'head-decoy-root.lock' 1 'FAIL: root node id changed: root -> realroot'
  run_scenario 'head .root missing errors' 'head-root-missing.lock' 2 'head flake.lock: .root missing or not a string (got null)'
  run_scenario 'head .root non-string errors' 'head-root-nonstring.lock' 2 'head flake.lock: .root missing or not a string (got {"bogus":1})'
  # Naming the entry point is what separates this from the plain routine
  # bump: the two resolve identically shaped graphs under different root ids.
  run_pair_scenario 'alt root id routine bump passes' 'base-alt-root.lock' 'head-alt-root-routine.lock' 0 \
    'provenance OK: entry "top"; top-level inputs resolved: 2 (0 via follows, max depth 0); shared nodes compared: 3; transitive churn tolerated: 0 added, 0 removed'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
