#!/usr/bin/env bash
# tests/check-pre-commit-hooks-sha-parity.test.sh
#
# Failure-mode harness for scripts/check-pre-commit-hooks-sha-parity.sh.
# Mirrors the pattern in tests/check-tag-protection.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-pre-commit-hooks-sha-parity.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-pre-commit-hooks-sha-parity"

failures=0

# @description Run the script with a fixture pair; assert exit code +
# stderr substring.
# @arg $1 scenario name
# @arg $2 fixture subdir under FIXTURES
# @arg $3 expected exit code (0 pass, 1 drift, 2 tooling error)
# @arg $4 expected stderr substring (empty skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  FLAKE_NIX_OVERRIDE="${FIXTURES}/${fixture_dir}/flake.nix" \
    FLAKE_LOCK_OVERRIDE="${FIXTURES}/${fixture_dir}/flake.lock" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

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

  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  run_scenario 'matched SHAs pass' \
    'good' 0 ''
  run_scenario 'SHA mismatch fails' \
    'bad-mismatch' 1 'SHA drift'
  run_scenario 'missing URL fails' \
    'bad-no-url' 1 'no github:cachix/git-hooks.nix'
  run_scenario 'missing lock node fails' \
    'bad-no-lock-node' 1 'no nodes'
  # An absent input file yields no SHA to compare, so it cannot be
  # reported as a parity drift.
  run_scenario 'absent input files are a tooling error' \
    'no-such-fixture' 2 'flake.nix not found'
  # A malformed flake.lock payload is a could-not-run, not drift or a
  # raw jq crash: each scenario keeps a valid flake.nix URL and varies
  # only the lock payload, naming the source kind rather than the
  # fixture path.
  #
  # Each expectation carries the `pre-commit hook parity` subject. On a
  # live run this script names its source `flake.lock`, which is also
  # what check-flake-lock-provenance.sh names for the head lock it
  # reads, so the source alone identifies neither. The subject does, and
  # asserting it here is what keeps it from being dropped: a collision
  # that lives in another script is invisible to the per-harness
  # discrimination gate.
  run_scenario 'whitespace-only flake.lock is a tooling error' \
    'bad-lock-empty' 2 'pre-commit hook parity: empty payload from FLAKE_LOCK_OVERRIDE'
  run_scenario 'flake.lock that is not JSON is a tooling error' \
    'bad-lock-not-json' 2 'pre-commit hook parity: payload from FLAKE_LOCK_OVERRIDE is not valid JSON'
  run_scenario 'boolean-typed flake.lock is a tooling error' \
    'bad-lock-wrong-type' 2 \
    'pre-commit hook parity: unexpected payload shape from FLAKE_LOCK_OVERRIDE: payload is boolean, want object'
  # flake.nix resolves (so the URL-SHA extraction that runs first
  # succeeds) but flake.lock itself is absent — a could-not-run on the
  # payload read, not the empty/not-JSON/wrong-type shape gate above.
  run_scenario 'absent flake.lock is a tooling error' \
    'bad-lock-absent' 2 'pre-commit hook parity: payload from FLAKE_LOCK_OVERRIDE not found'
  # The shape gate proves `.nodes` is an object, not that this node is
  # one. A node holding a scalar kills the walk into `.locked` with jq's
  # own exit 5 — outside the convention — where an absent node stays the
  # drift verdict the scenario above covers.
  run_scenario 'scalar pre-commit-hooks node is a tooling error' \
    'bad-lock-scalar-node' 2 'cannot read nodes["pre-commit-hooks"].locked.rev from'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
