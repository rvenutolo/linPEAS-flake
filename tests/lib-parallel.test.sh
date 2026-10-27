#!/usr/bin/env bash
# @subject scripts/lib/parallel.sh
# tests/lib-parallel.test.sh — proves scripts/lib/parallel.sh runs a
# caller's function over a list of names with at most the configured
# number of workers at once, captures each run's output, status and
# seconds into that run's own slot files, prints one `done:` line per
# name, keeps the batch going past a failure, and refuses a worker
# count that is not a positive integer or a batch with no names.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/ascii-match.sh
source "${REPO_ROOT}/scripts/lib/ascii-match.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/parallel.sh"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run a library-driving snippet as its own bash process so
# that `run_parallel`'s `exit 2` ends only that process, capture its
# streams, and record the outcome with the discrimination gate. Sets `rc`
# in the calling scope. The snippet defines `probe` and names the entries;
# `RESULT` is the slot directory, created fresh per scenario, and
# `RUNNING` an empty directory the concurrency scenarios mark.
# @arg $1 scenario name  @arg $2 asserted substring ('' if none)
# @arg $3 snippet body
function run_scenario() {
  local -r name="$1" substring="$2" body="$3"
  local -r script="${work}/${name}.sh"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  mkdir --parents -- "${work}/${name}.result" "${work}/${name}.running"
  rc=0
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf "IFS=\$'\\\\n\\\\t'\n"
    printf 'source %q\n' "${LIB}"
    printf 'RESULT=%q\n' "${work}/${name}.result"
    printf 'RUNNING=%q\n' "${work}/${name}.running"
    printf '%s\n' "${body}"
    # shellcheck disable=SC2016 # the line is bash source for the child process, which expands it
    printf 'printf "rc=%%d\\n" "${batch_rc}"\n'
  } >"${script}"
  bash "${script}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# @description Print the largest integer held on any line of the `.peak`
# files of a scenario's slot directory; a scenario with none is a could-not-run.
# @arg $1 scenario name
function max_peak() {
  local peak=0 f n
  local -a peaks=()
  glob_into peaks 'peak files' "${work}/$1.result/*.peak"
  for f in "${peaks[@]}"; do
    while IFS= read -r n; do
      ((n > peak)) && peak="${n}"
    done <"${f}"
  done
  printf '%d\n' "${peak}"
}

# 1. all-pass — every entry runs, each gets its slot files, and the batch
# returns 0.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'all-pass' 'done: ap-c pass' '
function probe() { printf "ran %s\n" "$1"; }
batch_rc=0
run_parallel probe "${RESULT}" ap-a ap-b ap-c
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'rc=0' "${work}/all-pass.out" &&
  grep --fixed-strings --quiet -- 'done: ap-a pass' "${work}/all-pass.out" &&
  grep --fixed-strings --quiet -- 'done: ap-b pass' "${work}/all-pass.out" &&
  [[ "$(<"${work}/all-pass.result/000.name")" == ap-a ]] &&
  [[ "$(<"${work}/all-pass.result/001.name")" == ap-b ]] &&
  [[ "$(<"${work}/all-pass.result/002.name")" == ap-c ]] &&
  [[ "$(<"${work}/all-pass.result/000.rc")" == 0 ]] &&
  [[ "$(<"${work}/all-pass.result/001.rc")" == 0 ]] &&
  [[ "$(<"${work}/all-pass.result/002.rc")" == 0 ]] &&
  [[ "$(<"${work}/all-pass.result/002.out")" == 'ran ap-c' ]] &&
  ascii_match "$(<"${work}/all-pass.result/002.secs")" '^[0-9]+$'; then
  pass 'all-pass: three entries run, slots in roster order, batch completes'
else
  fail "all-pass: expected rc=0 with three pass lines and ordered slots, got exit ${rc}"
  cat -- "${work}/all-pass.out" "${work}/all-pass.err" >&2
  ls -- "${work}/all-pass.result" >&2 || true
fi

# 2. one-fail — a failing entry marks its own slot and line, the entries
# after it still run, and the batch still completes (its verdict is in
# the slot files, not the return).
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'one-fail' 'done: of-b FAIL' '
function probe() { if [[ $1 == of-b ]]; then exit 137; fi; printf "ran %s\n" "$1"; }
batch_rc=0
run_parallel probe "${RESULT}" of-a of-b of-c
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'rc=0' "${work}/one-fail.out" &&
  grep --fixed-strings --quiet -- 'done: of-c pass' "${work}/one-fail.out" &&
  [[ "$(<"${work}/one-fail.result/001.rc")" == 137 ]] &&
  [[ "$(<"${work}/one-fail.result/002.rc")" == 0 ]]; then
  pass 'one-fail: the failing entry records 137, the rest run, the batch completes'
else
  fail "one-fail: expected the batch to complete with of-c still run, got exit ${rc}"
  cat -- "${work}/one-fail.out" "${work}/one-fail.err" >&2
fi

# 3. fn-writes-nothing — a function that prints nothing and exits 0 is a
# pass, not a missing result.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'fn-writes-nothing' 'done: fwn-a pass' '
function probe() { :; }
batch_rc=0
run_parallel probe "${RESULT}" fwn-a
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'rc=0' "${work}/fn-writes-nothing.out" &&
  [[ -f ${work}/fn-writes-nothing.result/000.out ]] &&
  [[ ! -s ${work}/fn-writes-nothing.result/000.out ]]; then
  pass 'fn-writes-nothing: silent success is a pass with an empty .out'
else
  fail "fn-writes-nothing: expected rc=0 and an empty .out, got exit ${rc}"
  cat -- "${work}/fn-writes-nothing.out" "${work}/fn-writes-nothing.err" >&2
fi

# 4. late-writer — a grandchild that keeps writing after its entry exits
# reaches that entry's own .out, never a sibling's and never the parent's
# streams.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'late-writer' 'done: lw-b pass' '
function probe() {
  if [[ $1 == lw-a ]]; then ( sleep 0.3; printf "late\n" ) & return 0; fi
  printf "b-out\n"
}
batch_rc=0
run_parallel probe "${RESULT}" lw-a lw-b
sleep 0.5
'
if [[ ${rc} -eq 0 ]] &&
  [[ "$(<"${work}/late-writer.result/001.out")" == 'b-out' ]] &&
  grep --fixed-strings --quiet -- 'late' "${work}/late-writer.result/000.out" &&
  ! grep --fixed-strings --quiet -- 'late' "${work}/late-writer.out"; then
  pass 'late-writer: a late grandchild write stays in its own slot'
else
  fail "late-writer: expected late in lw-a .out only and lw-b .out to be exactly b-out, got exit ${rc}"
  cat -- "${work}/late-writer.out" "${work}/late-writer.err" "${work}"/late-writer.result/*.out >&2
fi

# 5. output-captured — both streams of the entry land in its .out and
# neither reaches the parent's streams.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'output-captured' 'done: oc-a pass' '
function probe() { printf "to-stdout\n"; printf "to-stderr\n" >&2; }
batch_rc=0
run_parallel probe "${RESULT}" oc-a
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'to-stdout' "${work}/output-captured.result/000.out" &&
  grep --fixed-strings --quiet -- 'to-stderr' "${work}/output-captured.result/000.out" &&
  ! grep --fixed-strings --quiet -- 'to-std' "${work}/output-captured.out" &&
  ! grep --fixed-strings --quiet -- 'to-std' "${work}/output-captured.err"; then
  pass 'output-captured: stdout and stderr are buffered into the slot only'
else
  fail "output-captured: expected both streams in the slot and none in the parent, got exit ${rc}"
  cat -- "${work}/output-captured.out" "${work}/output-captured.err" >&2
fi

# 6. workers-one-serial — one worker runs the entries one after another in
# roster order, so the done lines come out in that order.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'workers-one-serial' 'done: wos-a pass' '
function probe() { sleep 0.2; }
batch_rc=0
CHECK_WORKERS_OVERRIDE=1 run_parallel probe "${RESULT}" wos-c wos-b wos-a
'
if [[ ${rc} -eq 0 ]] &&
  [[ "$(grep --fixed-strings -- 'done: ' "${work}/workers-one-serial.out" | tr '\n' ' ')" == 'done: wos-c pass done: wos-b pass done: wos-a pass ' ]]; then
  pass 'workers-one-serial: one worker finishes entries in roster order'
else
  fail "workers-one-serial: expected done lines c b a, got exit ${rc}"
  cat -- "${work}/workers-one-serial.out" "${work}/workers-one-serial.err" >&2
fi

# 7. concurrency-bounded — with two workers and four entries that each
# hold a marker while sleeping, the most markers any entry sees on entry
# or exit is two. The sleep is a full second so the overlap is seen even
# when this harness itself runs beside others on a loaded runner, and
# the markers are counted by glob, which reads the directory without
# touching entries a sibling may be removing at that moment.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'concurrency-bounded' 'done: cb-d pass' '
function probe() {
  local -a markers=()
  mkdir -- "${RUNNING}/$1"
  glob_into markers markers "${RUNNING}/*"
  printf "%d\n" "${#markers[@]}" >"$2.peak"
  sleep 1
  glob_into markers markers "${RUNNING}/*"
  printf "%d\n" "${#markers[@]}" >>"$2.peak"
  rmdir -- "${RUNNING}/$1"
}
batch_rc=0
CHECK_WORKERS_OVERRIDE=2 run_parallel probe "${RESULT}" cb-a cb-b cb-c cb-d
'
peak="$(max_peak concurrency-bounded)"
if [[ ${rc} -eq 0 && ${peak} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'done: cb-d pass' "${work}/concurrency-bounded.out"; then
  pass 'concurrency-bounded: two workers run at most two entries at once'
else
  fail "concurrency-bounded: expected peak 2 and every entry passing, got peak ${peak} exit ${rc}"
  cat -- "${work}/concurrency-bounded.out" "${work}/concurrency-bounded.err" "${work}"/concurrency-bounded.result/*.out >&2
fi

# 8. concurrency-one — the same probe under one worker never overlaps.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'concurrency-one' 'done: co-c pass' '
function probe() {
  local -a markers=()
  mkdir -- "${RUNNING}/$1"
  glob_into markers markers "${RUNNING}/*"
  printf "%d\n" "${#markers[@]}" >"$2.peak"
  sleep 0.2
  glob_into markers markers "${RUNNING}/*"
  printf "%d\n" "${#markers[@]}" >>"$2.peak"
  rmdir -- "${RUNNING}/$1"
}
batch_rc=0
CHECK_WORKERS_OVERRIDE=1 run_parallel probe "${RESULT}" co-a co-b co-c
'
peak="$(max_peak concurrency-one)"
if [[ ${rc} -eq 0 && ${peak} -eq 1 ]] &&
  grep --fixed-strings --quiet -- 'done: co-c pass' "${work}/concurrency-one.out"; then
  pass 'concurrency-one: one worker never overlaps entries'
else
  fail "concurrency-one: expected peak 1, got peak ${peak} exit ${rc}"
  cat -- "${work}/concurrency-one.out" "${work}/concurrency-one.err" >&2
fi

# 9. bad-workers-zero — a worker count of 0 is a usage error naming the
# value, exit 2, and no entry runs.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'bad-workers-zero' 'CHECK_WORKERS_OVERRIDE must be a positive integer, got: 0' '
function probe() { printf "ran %s\n" "$1"; }
batch_rc=0
CHECK_WORKERS_OVERRIDE=0 run_parallel probe "${RESULT}" bwz-a
'
if [[ ${rc} -eq 2 ]] && [[ ! -e ${work}/bad-workers-zero.result/000.out ]]; then
  pass 'bad-workers-zero: 0 workers is exit 2 and runs nothing'
else
  fail "bad-workers-zero: expected exit 2 and no slot, got exit ${rc}"
  cat -- "${work}/bad-workers-zero.out" "${work}/bad-workers-zero.err" >&2
fi

# 10. bad-workers-text — a non-numeric count is the same usage error.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'bad-workers-text' 'CHECK_WORKERS_OVERRIDE must be a positive integer, got: abc' '
function probe() { printf "ran %s\n" "$1"; }
batch_rc=0
CHECK_WORKERS_OVERRIDE=abc run_parallel probe "${RESULT}" bwt-a
'
if [[ ${rc} -eq 2 ]]; then
  pass 'bad-workers-text: a non-numeric count is exit 2'
else
  fail "bad-workers-text: expected exit 2, got exit ${rc}"
  cat -- "${work}/bad-workers-text.out" "${work}/bad-workers-text.err" >&2
fi

# 11. no-entries — a batch with nothing to run is a usage error, never a
# silent pass.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'no-entries' 'run_parallel: no entries to run' '
function probe() { printf "ran %s\n" "$1"; }
batch_rc=0
run_parallel probe "${RESULT}"
'
if [[ ${rc} -eq 2 ]]; then
  pass 'no-entries: an empty batch is exit 2'
else
  fail "no-entries: expected exit 2, got exit ${rc}"
  cat -- "${work}/no-entries.out" "${work}/no-entries.err" >&2
fi

# 12. nproc-default — with no override the count comes from nproc and the
# batch runs.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'nproc-default' 'done: npd-a pass' '
function probe() { printf "ran %s\n" "$1"; }
batch_rc=0
unset CHECK_WORKERS_OVERRIDE
run_parallel probe "${RESULT}" npd-a
'
if [[ ${rc} -eq 0 ]] && grep --fixed-strings --quiet -- 'rc=0' "${work}/nproc-default.out"; then
  pass 'nproc-default: no override uses nproc and runs the batch'
else
  fail "nproc-default: expected rc=0, got exit ${rc}"
  cat -- "${work}/nproc-default.out" "${work}/nproc-default.err" >&2
fi

# 13. errexit-inside-fn — a failing command in the middle of the function
# ends it as a failure; the function is not left running with errexit
# suspended by the helper's own status handling.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'errexit-inside-fn' 'done: eif-a FAIL' '
function probe() { false; printf "after-false\n"; }
batch_rc=0
run_parallel probe "${RESULT}" eif-a
'
if [[ ${rc} -eq 0 ]] &&
  [[ "$(<"${work}/errexit-inside-fn.result/000.rc")" == 1 ]] &&
  ! grep --fixed-strings --quiet -- 'after-false' "${work}/errexit-inside-fn.result/000.out"; then
  pass 'errexit-inside-fn: a failing command inside the function fails the entry at that point'
else
  fail "errexit-inside-fn: expected 000.rc of 1 and no after-false, got exit ${rc}"
  cat -- "${work}/errexit-inside-fn.out" "${work}/errexit-inside-fn.err" "${work}/errexit-inside-fn.result/000.out" >&2
fi

# 14. worker-killed — an entry whose worker dies before it can write its
# status files is a could-not-run for the whole batch, never a pass with
# one row fewer. The function kills the worker that invoked it, read as
# its own parent pid, before the worker's trap can record anything.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'worker-killed' 'run_parallel: 1 of 2 entries left no status' '
function probe() {
  if [[ $1 == wk-b ]]; then
    IFS=" " read -r _ _ _ worker _ <"/proc/${BASHPID}/stat"
    kill -KILL "${worker}"
    sleep 1
  fi
  printf "ran %s\n" "$1"
}
batch_rc=0
CHECK_WORKERS_OVERRIDE=1 run_parallel probe "${RESULT}" wk-a wk-b
'
if [[ ${rc} -eq 2 ]]; then
  pass 'worker-killed: a worker that dies without a status is exit 2'
else
  fail "worker-killed: expected exit 2, got exit ${rc}"
  cat -- "${work}/worker-killed.out" "${work}/worker-killed.err" >&2
fi

# 15. fn-killed-by-signal — when the function's own process is killed by
# a signal, the worker's job message about it lands in that entry's .out,
# not on the parent's streams, and the entry records the signal status.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'fn-killed-by-signal' 'done: fks-a FAIL' '
function probe() {
  if [[ $1 == fks-a ]]; then kill -KILL "${BASHPID}"; fi
  printf "ran %s\n" "$1"
}
batch_rc=0
run_parallel probe "${RESULT}" fks-a fks-b
'
if [[ ${rc} -eq 0 ]] &&
  [[ "$(<"${work}/fn-killed-by-signal.result/000.rc")" == 137 ]] &&
  grep --fixed-strings --quiet -- 'Killed' "${work}/fn-killed-by-signal.result/000.out" &&
  ! grep --fixed-strings --quiet -- 'Killed' "${work}/fn-killed-by-signal.out" &&
  ! grep --fixed-strings --quiet -- 'Killed' "${work}/fn-killed-by-signal.err"; then
  pass 'fn-killed-by-signal: the job message goes to the killed entry slot only'
else
  fail "fn-killed-by-signal: expected 000.rc of 137 and Killed in 000.out only, got exit ${rc}"
  cat -- "${work}/fn-killed-by-signal.out" "${work}/fn-killed-by-signal.err" "${work}"/fn-killed-by-signal.result/*.out >&2
fi

# 16. too-many-entries — a batch of more than 999 names is a usage error
# and no entry runs, which keeps every slot index inside three digits with
# one to spare.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'too-many-entries' 'run_parallel: at most 999 entries, got 1000' '
function probe() { :; }
batch_rc=0
mapfile -t names < <(seq 1000)
run_parallel probe "${RESULT}" "${names[@]}"
'
if [[ ${rc} -eq 2 ]] && [[ ! -e ${work}/too-many-entries.result/000.out ]]; then
  pass 'too-many-entries: 1000 names is exit 2 and runs nothing'
else
  fail "too-many-entries: expected exit 2 and no slot, got exit ${rc}"
  cat -- "${work}/too-many-entries.out" "${work}/too-many-entries.err" >&2
fi

# 17. max-entries — exactly 999 names is within the limit and runs.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'max-entries' 'done: 999 pass' '
function probe() { :; }
batch_rc=0
mapfile -t names < <(seq 999)
run_parallel probe "${RESULT}" "${names[@]}"
'
if [[ ${rc} -eq 0 ]] && [[ "$(<"${work}/max-entries.result/998.name")" == 999 ]]; then
  pass 'max-entries: 999 names run, the last in slot 998'
else
  fail "max-entries: expected rc=0 and slot 998 named 999, got exit ${rc}"
  cat -- "${work}/max-entries.err" >&2
fi

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
