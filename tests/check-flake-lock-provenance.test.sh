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
  local out_file
  out_file="$(mktemp)"
  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/${base}" \
    HEAD_LOCK_FILE="${FIXTURES}/${head}" \
    timeout "${SCENARIO_TIMEOUT_SECS}" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
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
  harness_assert_record "${name}" "${expected_msg}" "${out_file}"
  rm --force -- "${out_file}"
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

# @arg $1 scenario name ; missing base => operational error (exit 2)
function run_missing_base() {
  local -r name="$1"
  local out_file
  out_file="$(mktemp)"
  local actual_exit=0
  BASE_LOCK_FILE="${FIXTURES}/does-not-exist.lock" \
    HEAD_LOCK_FILE="${FIXTURES}/base.lock" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit 2)\n' "${name}"
  fi
  harness_assert_record "${name}" '' "${out_file}"
  rm --force -- "${out_file}"
}

function main() {
  # A top-level input whose resolved source changed reports the same
  # `top-level input repointed` line whether or not its node was also
  # renamed; the rename shows only in the tolerated add/remove notes, which
  # the rename-without-repoint fixture emits too. So no token separates the
  # rename+repoint fixture from the plain owner/type repoints — those two
  # are pinned to the `node repointed` line they alone emit, and this pair
  # is exempted.
  harness_assert_exempt 'FAIL: top-level input repointed: alpha' \
    'top-level owner change fails' \
    'the top-level repoint diagnostic names the input, not the node rename that accompanies it here'
  harness_assert_exempt 'FAIL: top-level input repointed: alpha' \
    'top-level type change fails' \
    'the top-level repoint diagnostic names the input, not the node rename that accompanies it here'

  run_scenario 'routine bump passes' 'head-routine.lock' 0 'provenance OK'
  run_scenario 'top-level owner change fails' 'head-toplevel-owner.lock' 1 'FAIL: node repointed: alpha'
  run_scenario 'top-level type change fails' 'head-toplevel-type.lock' 1 'FAIL: node repointed: alpha'
  run_scenario 'top-level input added fails' 'head-toplevel-added.lock' 1 'FAIL: top-level input added: delta'
  run_scenario 'top-level input removed fails' 'head-toplevel-removed.lock' 1 'FAIL: top-level input removed: beta'
  run_scenario 'transitive repoint fails' 'head-transitive-repoint.lock' 1 'FAIL: node repointed: gamma'
  run_scenario 'transitive node added tolerated' 'head-transitive-added.lock' 0 'provenance OK'
  run_scenario 'transitive node removed tolerated' 'head-transitive-removed.lock' 0 'provenance OK'
  run_scenario 'garbage head json errors' 'head-garbage.lock' 2 ''
  run_scenario 'top-level rename same source' 'head-toplevel-renamed-same.lock' 0 'provenance OK'
  run_scenario 'top-level rename + repoint fails' 'head-toplevel-renamed-repoint.lock' 1 'FAIL: top-level input repointed: alpha'
  run_missing_base 'missing base errors'

  run_follows_scenario 'follows routine bump passes' 'head-follows-routine.lock' 0 'provenance OK'
  run_follows_scenario 'string-to-array repoint fails' 'head-follows-string-to-array.lock' 1 'FAIL: top-level input repointed: gamma'
  run_follows_scenario 'array-to-array repoint fails' 'head-follows-array-change.lock' 1 'FAIL: top-level input repointed: beta'
  run_follows_scenario 'string-to-array same source passes' 'head-follows-string-to-array-same.lock' 0 'provenance OK'
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
  # work must not shorten how deep a legitimate `follows` chain may go.
  run_pair_scenario 'deep legal follows chain resolves' \
    'base-follows-deep.lock' 'base-follows-deep.lock' 0 'provenance OK'

  run_scenario 'decoy renamed root fails' 'head-decoy-root.lock' 1 'FAIL: root node id changed: root -> realroot'
  run_scenario 'head .root missing errors' 'head-root-missing.lock' 2 'head flake.lock: .root missing or not a string (got null)'
  run_scenario 'head .root non-string errors' 'head-root-nonstring.lock' 2 'head flake.lock: .root missing or not a string (got {"bogus":1})'
  run_pair_scenario 'alt root id routine bump passes' 'base-alt-root.lock' 'head-alt-root-routine.lock' 0 'provenance OK'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
