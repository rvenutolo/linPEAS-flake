#!/usr/bin/env bash
# tests/refresh-enforcement-matrix.test.sh
#
# Round-trip + drift + failure-mode harness for
# scripts/refresh-enforcement-matrix.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-enforcement-matrix.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/refresh-enforcement-matrix"

# Inline hook list keeps the harness independent of `nix eval` for the
# fixture scenarios. The real-index assertion deliberately omits the
# override so it exercises the live flake.
readonly FIXTURE_HOOKS=$'uses-sha-pinned\nrenovate-invariants\nharden-runner-first\nbogus\ny'

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# run_scenario <name> <fixture> <expected_exit> <expected_stderr_substring>
function run_scenario() {
  local -r name="$1" fixture="$2" expected_exit="$3" expected_stderr="$4"
  local stderr_file out_file actual_exit=0
  stderr_file="$(mktemp)"
  out_file="$(mktemp)"
  INVARIANT_INDEX_OVERRIDE="${FIXTURES}/${fixture}" \
    MATRIX_OUTPUT_OVERRIDE="${out_file}" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    fail "${name}: expected exit ${expected_exit}, got ${actual_exit}"
    cat -- "${stderr_file}" >&2
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    fail "${name}: stderr missing ${expected_stderr}"
    cat -- "${stderr_file}" >&2
  else
    pass "${name} (exit ${actual_exit})"
  fi
  rm --force -- "${stderr_file}" "${out_file}"
}

function main() {
  # Assertion 1: real index → real matrix → --check is clean (round-trip).
  "${SCRIPT}" >/dev/null
  if "${SCRIPT}" --check >/dev/null 2>&1; then
    pass 'real-index --check is clean after generate'
  else
    fail 'real-index --check failed right after generate'
  fi

  # Assertion 2: typoed enforcer reference → exit 2.
  SKIP_REVERSE_CHECK=1 PRECOMMIT_HOOK_NAMES_OVERRIDE="${FIXTURE_HOOKS}" \
    run_scenario 'typoed enforcer fails' \
    'bad-typo-enforcer.md' 2 'check-does-not-exist.sh'

  # Assertion 3: missing required field → exit 2.
  SKIP_REVERSE_CHECK=1 PRECOMMIT_HOOK_NAMES_OVERRIDE="${FIXTURE_HOOKS}" \
    run_scenario 'missing enforcer field fails' \
    'bad-missing-field.md' 2 'enforcer'

  # Assertion 4: orphan script (real check-*.sh not referenced) → exit 2.
  # Reverse check intentionally enabled here.
  PRECOMMIT_HOOK_NAMES_OVERRIDE="${FIXTURE_HOOKS}" \
    run_scenario 'orphan check-*.sh fails' \
    'bad-orphan-script.md' 2 'orphan'

  # Assertion 5: good fixture round-trips against pinned expected output.
  # Inject the hook-name list inline so the fixture round-trip doesn't
  # depend on the slow `nix eval` path and stays stable across flake
  # refactors.
  local out_file
  out_file="$(mktemp)"
  SKIP_REVERSE_CHECK=1 \
    PRECOMMIT_HOOK_NAMES_OVERRIDE=$'uses-sha-pinned\nrenovate-invariants\nharden-runner-first' \
    INVARIANT_INDEX_OVERRIDE="${FIXTURES}/good-index.md" \
    MATRIX_OUTPUT_OVERRIDE="${out_file}" \
    "${SCRIPT}" >/dev/null 2>&1
  if diff --unified "${FIXTURES}/expected-matrix.md" "${out_file}"; then
    pass 'good fixture matches expected matrix'
  else
    fail 'good fixture diverges from expected matrix'
  fi
  rm --force -- "${out_file}"

  if [[ ${failures} -gt 0 ]]; then
    printf '%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf 'all passed\n'
}

main "$@"
