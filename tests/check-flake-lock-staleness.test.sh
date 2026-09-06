#!/usr/bin/env bash
# tests/check-flake-lock-staleness.test.sh
#
# Verdict + failure-mode matrix for
# scripts/check-flake-lock-staleness.sh. Drives the check off fixture
# locks via FLAKE_LOCK_OVERRIDE, with STALENESS_NOW_EPOCH pinning "now"
# so a fixture's age — and therefore its verdict — cannot drift with the
# day the suite runs. Every fixture's lastModified is expressed as an
# offset from that one epoch. One live scenario at the end runs the
# check against the repo's own flake.lock on the wall clock.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-flake-lock-staleness.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-flake-lock-staleness"

# The epoch every fixture's ages are measured from. Changing it means
# regenerating every fixture; it is not a knob.
readonly NOW=1787000000

failures=0

# @arg $1 scenario name  @arg $2 lock fixture  @arg $3 expected exit
# @arg $4 expected output substring (empty skips)
function run_scenario() {
  local -r name="$1" fixture="$2" expected_exit="$3" expected_msg="$4"
  local out_file outcome_file
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  FLAKE_LOCK_OVERRIDE="${FIXTURES}/${fixture}" \
    STALENESS_NOW_EPOCH="${NOW}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
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

function main() {
  # The clean run asserts the whole summary, not the bare verdict: the
  # per-input age/bound pairs are the evidence that each input was
  # actually measured against its own threshold rather than a shared one.
  run_scenario 'every input within bounds passes' 'all-fresh.lock' 0 \
    'staleness OK: 5 input(s) within bounds (flake-parts=19d/120d nixpkgs=1d/14d nixpkgs-unstable=2d/14d pre-commit-hooks=102d/120d treefmt-nix=5d/120d)'

  # Both sides of both bounds. A threshold is only meaningful if the day
  # it starts firing is asserted, and the two tiers are asserted
  # separately so a change that collapses them into one cannot pass.
  run_scenario 'a fast input exactly at its bound passes' 'fast-at-bound.lock' 0 \
    'staleness OK: 5 input(s) within bounds (flake-parts=19d/120d nixpkgs=14d/14d nixpkgs-unstable=2d/14d pre-commit-hooks=102d/120d treefmt-nix=5d/120d)'
  run_scenario 'a fast input one day past its bound fails' 'fast-past-bound.lock' 1 \
    'STALE: nixpkgs last moved 15 days ago, over its 14-day bound'
  run_scenario 'a slow input exactly at its bound passes' 'slow-at-bound.lock' 0 \
    'staleness OK: 5 input(s) within bounds (flake-parts=19d/120d nixpkgs=1d/14d nixpkgs-unstable=2d/14d pre-commit-hooks=120d/120d treefmt-nix=5d/120d)'
  run_scenario 'a slow input one day past its bound fails' 'slow-past-bound.lock' 1 \
    'STALE: pre-commit-hooks last moved 121 days ago, over its 120-day bound'

  # Every stale input is reported in one run. A check that stopped at
  # the first would send a maintainer round the loop once per input.
  run_scenario 'every stale input is reported, not just the first' 'two-stale.lock' 1 \
    'FAILED — 2 of 5 input(s) past their bound'

  # The threshold table rots when an input is added to flake.nix and not
  # to it. The silent-pass version of that rot is a new input nobody
  # watches, so an unnamed input is a could-not-run.
  run_scenario 'an input with no declared threshold is a could-not-run' 'undeclared-input.lock' 2 \
    "no staleness threshold declared for top-level input 'newthing'"
  # A follows ref resolves to a node this repo does not pin directly, so
  # its age reports on somebody else's cadence. Guessing at one would be
  # worse than saying so.
  run_scenario 'a follows-shaped input is a could-not-run' 'follows-input.lock' 2 \
    "top-level input 'treefmt-nix' resolves through follows"
  run_scenario 'a node with no lastModified is a could-not-run' 'no-lastmodified.lock' 2 \
    "top-level input 'flake-parts' (node 'flake-parts') has no numeric locked.lastModified"
  run_scenario 'an entry node with no inputs is a could-not-run' 'no-toplevel-inputs.lock' 2 \
    'the entry node declares no top-level inputs'
  run_scenario 'a non-string .root is a could-not-run' 'root-nonstring.lock' 2 \
    '.root missing or not a string'

  # A lock that clears both shape probes can still hold a node the reads
  # below cannot index. jq dies there under its own status, which the
  # exit-code convention does not catalogue and no caller knows how to
  # read, so each read reports what it could not read.
  run_scenario 'an entry node that is not an object is a could-not-run' 'entry-node-nonobject.lock' 2 \
    "the entry node's input list could not be read"
  run_scenario 'an input node that is not an object is a could-not-run' 'input-node-nonobject.lock' 2 \
    "top-level input 'nixpkgs' (node 'nixpkgs') could not be read"

  # Time is an input, so a caller that supplies a broken one must be
  # told rather than silently falling back to the wall clock — a
  # fallback would make the verdict depend on the day.
  local out_file outcome_file actual_exit=0
  out_file="$(mktemp)"
  FLAKE_LOCK_OVERRIDE="${FIXTURES}/all-fresh.lock" \
    STALENESS_NOW_EPOCH="not-a-timestamp" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 2 ]] ||
    ! grep --fixed-strings --quiet -- 'STALENESS_NOW_EPOCH is not a unix timestamp' "${out_file}"; then
    printf 'FAIL: a non-numeric now is a could-not-run — exit %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: a non-numeric now is a could-not-run (exit %d)\n' "${actual_exit}"
  fi
  rm --force -- "${out_file}"

  # The absent-payload sentence comes from the shared reader and names
  # the override by kind, never the path a scenario pointed it at.
  actual_exit=0
  out_file="$(mktemp)"
  FLAKE_LOCK_OVERRIDE="${FIXTURES}/does-not-exist.lock" \
    STALENESS_NOW_EPOCH="${NOW}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 2 ]] ||
    ! grep --fixed-strings --quiet -- 'payload from FLAKE_LOCK_OVERRIDE not found' "${out_file}"; then
    printf 'FAIL: an absent lock is a could-not-run — exit %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: an absent lock is a could-not-run (exit %d)\n' "${actual_exit}"
  fi
  rm --force -- "${out_file}"

  # jq absent from PATH is a fault in the environment, not in the lock.
  # The shape probes read the payload through jq, so without it they test
  # nothing — and a probe that ran no test cannot name a defect in a file
  # it never parsed.
  #
  # The environment is built as a symlink farm holding exactly the tools
  # the check needs, rather than by stripping jq's directory out of the
  # ambient PATH: on this tree several tools share one directory, so
  # stripping would take the reader's `cat` along with `jq` and the run
  # would die before reaching the guard under test.
  local farm tool bash_bin
  farm="$(mktemp --directory)"
  bash_bin="$(command -v bash)"
  for tool in cat date; do
    ln --symbolic -- "$(command -v "${tool}")" "${farm}/${tool}"
  done
  actual_exit=0
  out_file="$(mktemp)"
  outcome_file="$(mktemp)"
  env --unset=BASH_ENV PATH="${farm}" \
    FLAKE_LOCK_OVERRIDE="${FIXTURES}/all-fresh.lock" \
    STALENESS_NOW_EPOCH="${NOW}" \
    "${bash_bin}" "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  if [[ ${actual_exit} -ne 2 ]] ||
    ! grep --fixed-strings --quiet -- 'missing required tool: jq' "${out_file}"; then
    printf 'FAIL: an absent jq names the tool, not the lock — exit %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: an absent jq names the tool, not the lock (exit %d)\n' "${actual_exit}"
  fi
  harness_assert_record 'an absent jq names the tool, not the lock' \
    'missing required tool: jq' "${outcome_file}" "${out_file}"
  rm --recursive --force -- "${outcome_file}" "${out_file}" "${farm}"

  # The live tree must satisfy its own check. This is the scenario that
  # notices a real input going stale, and the only one whose input is
  # not a fixture.
  actual_exit=0
  out_file="$(mktemp)"
  (cd "${REPO_ROOT}" && "${SCRIPT}") >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: live: the repo flake.lock is within bounds — exit %d\n' "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: live: the repo flake.lock is within bounds (exit %d)\n' "${actual_exit}"
  fi
  rm --force -- "${out_file}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
