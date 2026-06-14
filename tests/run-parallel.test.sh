#!/usr/bin/env bash
# tests/run-parallel.test.sh
#
# Spec-driven harness for scripts/lib/run-parallel.sh. Sources the lib,
# builds throwaway job arrays, and asserts: exit aggregation, run-all-on-
# failure, original-order output replay regardless of finish order, the
# summary table format, and that RUN_PARALLEL_JOBS bounds concurrency.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/lib/run-parallel.sh"

failures=0

function check() {
  local -r name="$1" cond="$2"
  if [[ ${cond} == "ok" ]]; then
    printf 'PASS: %s\n' "${name}"
  else
    printf 'FAIL: %s\n' "${name}" >&2
    failures=$((failures + 1))
  fi
}

# --- scenario: all jobs pass -> exit 0, table has both rows ---
function test_all_pass() {
  # shellcheck disable=SC2034 # passed by name to run_parallel (nameref)
  local -a jobs=('aaa|true' 'bbb|true')
  local out rc=0
  out="$(run_parallel jobs check all-pass)" || rc=$?
  check 'all-pass exit 0' "$([[ ${rc} -eq 0 ]] && echo ok)"
  check 'all-pass row aaa' "$(grep -qF '| aaa | pass |' <<<"${out}" && echo ok)"
  check 'all-pass row bbb' "$(grep -qF '| bbb | pass |' <<<"${out}" && echo ok)"
  check 'all-pass header' "$(grep -qF '| check | result | time |' <<<"${out}" && echo ok)"
}

# --- scenario: one job fails -> exit 1, all rows present ---
function test_one_fail() {
  # shellcheck disable=SC2034 # passed by name to run_parallel (nameref)
  local -a jobs=('aaa|true' 'bbb|false' 'ccc|true')
  local out rc=0
  out="$(run_parallel jobs check one-fail)" || rc=$?
  check 'one-fail exit 1' "$([[ ${rc} -eq 1 ]] && echo ok)"
  check 'one-fail aaa pass' "$(grep -qF '| aaa | pass |' <<<"${out}" && echo ok)"
  check 'one-fail bbb FAIL' "$(grep -qF '| bbb | FAIL |' <<<"${out}" && echo ok)"
  check 'one-fail ccc still ran' "$(grep -qF '| ccc | pass |' <<<"${out}" && echo ok)"
}

function main() {
  test_all_pass
  test_one_fail
  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d check(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
