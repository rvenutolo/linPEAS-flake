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

# --- scenario: output replayed in array order despite reverse finish order ---
function test_order_preserved() {
  # shellcheck disable=SC2034 # passed by name to run_parallel (nameref)
  local -a jobs=(
    'aaa|sleep 0.3; echo marker-0'
    'bbb|sleep 0.2; echo marker-1'
    'ccc|sleep 0.1; echo marker-2'
  )
  local out
  out="$(RUN_PARALLEL_JOBS=4 run_parallel jobs check order)"
  local n0 n1 n2
  n0="$(grep -n marker-0 <<<"${out}" | head -1 | cut -d: -f1)"
  n1="$(grep -n marker-1 <<<"${out}" | head -1 | cut -d: -f1)"
  n2="$(grep -n marker-2 <<<"${out}" | head -1 | cut -d: -f1)"
  check 'order 0<1' "$([[ ${n0} -lt ${n1} ]] && echo ok)"
  check 'order 1<2' "$([[ ${n1} -lt ${n2} ]] && echo ok)"
}

# --- scenario: RUN_PARALLEL_JOBS caps live concurrency ---
function test_concurrency_bound() {
  local cdir
  cdir="$(mktemp -d)"
  # Body runs inside each job's own subshell; $d, $(cat ...), flock vars must
  # stay literal here. Only ${cdir} is interpolated via the concatenation.
  # shellcheck disable=SC2016 # literal expansions are intentional (job body)
  local body='
    d="'"${cdir}"'"
    ( flock 9
      live=$(( $(cat "$d/live" 2>/dev/null || echo 0) + 1 ))
      echo "$live" >"$d/live"
      peak=$(cat "$d/peak" 2>/dev/null || echo 0)
      (( live > peak )) && echo "$live" >"$d/peak"
    ) 9>"$d/lock"
    sleep 0.2
    ( flock 9
      live=$(( $(cat "$d/live") - 1 ))
      echo "$live" >"$d/live"
    ) 9>"$d/lock"'
  # shellcheck disable=SC2034 # passed by name to run_parallel (nameref)
  local -a jobs=(
    "j0|${body}" "j1|${body}" "j2|${body}"
    "j3|${body}" "j4|${body}" "j5|${body}"
  )
  RUN_PARALLEL_JOBS=2 run_parallel jobs check bound >/dev/null
  local peak
  peak="$(cat "${cdir}/peak")"
  check 'concurrency peak <= 2' "$([[ ${peak} -le 2 ]] && echo ok)"
  check 'concurrency peak >= 2' "$([[ ${peak} -ge 2 ]] && echo ok)"
  rm --recursive --force -- "${cdir}"
}

function main() {
  test_all_pass
  test_one_fail
  test_order_preserved
  test_concurrency_bound
  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d check(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
