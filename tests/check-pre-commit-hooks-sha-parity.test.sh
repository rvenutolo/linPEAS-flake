#!/usr/bin/env bash
# tests/check-pre-commit-hooks-sha-parity.test.sh
#
# Failure-mode harness for scripts/check-pre-commit-hooks-sha-parity.sh.
# Fixture-driven: each scenario asserts exit code and output.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"
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

# @description Run the script under en_US.UTF-8 on a copy of the good
# fixture pair whose URL SHA and lock rev are replaced, and compare exit
# code and the whole of stderr. In that locale a bash `[0-9a-f]` range
# also matches non-ASCII characters.
# @arg $1 scenario name  @arg $2 URL SHA  @arg $3 lock rev
# @arg $4 expected exit  @arg $5 the whole expected stderr
function run_en_us_scenario() {
  local -r name="$1" url_sha="$2" lock_rev="$3" expected_exit="$4" expected_stderr="$5"
  local -r good_sha='61ab0e80d9c7ab14c256b5b453d8b3fb0189ba0a'
  local dir stderr_file stdout_file outcome_file
  dir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  sed "s|${good_sha}|${url_sha}|" -- "${FIXTURES}/good/flake.nix" >"${dir}/flake.nix"
  sed "s|${good_sha}|${lock_rev}|g" -- "${FIXTURES}/good/flake.lock" >"${dir}/flake.lock"

  local actual_exit=0
  LC_ALL=en_US.UTF-8 FLAKE_NIX_OVERRIDE="${dir}/flake.nix" \
    FLAKE_LOCK_OVERRIDE="${dir}/flake.lock" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} || "$(cat -- "${stderr_file}")" != "${expected_stderr}" ]]; then
    printf 'FAIL: %s — expected exit %d and stderr %q; got exit %d and stderr %q\n' \
      "${name}" "${expected_exit}" "${expected_stderr}" "${actual_exit}" \
      "$(cat -- "${stderr_file}")" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --recursive --force -- "${dir}" "${stderr_file}" "${stdout_file}" "${outcome_file}"
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
  # The lock rev is held to 40 lowercase hex digits under any locale; a
  # URL SHA that is an ASCII prefix of it would otherwise match.
  require_locale_gap en_US.UTF-8 || exit 1
  run_en_us_scenario 'non-ASCII letter in the lock rev fails under en_US.UTF-8' \
    61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0 61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0é 1 \
    'lock rev has unexpected shape: 61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0é'
  run_en_us_scenario 'non-ASCII digit in the lock rev fails under en_US.UTF-8' \
    61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0 61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0５ 1 \
    'lock rev has unexpected shape: 61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0５'
  # grep extracts the URL SHA through the same range, so under en_US.UTF-8
  # the non-ASCII letter reaches the shape gate rather than ending the
  # match early.
  run_en_us_scenario 'non-ASCII letter in the URL SHA fails under en_US.UTF-8' \
    61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0é 61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0a 1 \
    'extracted URL SHA has unexpected shape: 61ab0e80d9c7ab14c256b5b453d8b3fb0189bb0é'
  local -r full_sha='61ab0e80d9c7ab14c256b5b453d8b3fb0189ba0a'
  # A full-length value with one stray character at either end is not a
  # SHA either: the shape gates are anchored, not substring searches.
  run_en_us_scenario 'non-ASCII letter before the URL SHA fails under en_US.UTF-8' \
    é61ab0e80d9c7ab14c256b5b453d8 "${full_sha}" 1 \
    'extracted URL SHA has unexpected shape: é61ab0e80d9c7ab14c256b5b453d8'
  run_en_us_scenario 'non-ASCII letter before a full lock rev fails under en_US.UTF-8' \
    "${full_sha}" "é${full_sha}" 1 \
    "lock rev has unexpected shape: é${full_sha}"
  run_en_us_scenario 'non-ASCII letter after a full lock rev fails under en_US.UTF-8' \
    "${full_sha}" "${full_sha}é" 1 \
    "lock rev has unexpected shape: ${full_sha}é"
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
