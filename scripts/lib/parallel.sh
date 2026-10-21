# scripts/lib/parallel.sh
#
# @description Run a caller's function over a list of names with a bounded
# number of workers at once, keeping each run's output apart. A runner
# that executes its checks one after another spends the job's wall time
# on their sum, on a runner with several CPUs; this helper spends it on
# roughly the slowest check plus the leftovers. Each run's stdout and
# stderr are buffered into its own slot file, and the only text the
# helper prints while runs are in flight is one `done:` line per name, so
# the caller replays the buffered output in roster order afterwards and
# the log reads the same whatever order the runs finished in. There is no
# signal handling: a Ctrl-C reaches every process in the foreground group
# already, and a cancelled or timed-out CI job ends the whole runner. There
# is no worker budget shared between a runner and a parallel harness it
# runs: every level reads `nproc`, and the brief oversubscription that
# nesting causes is bounded by the product of the two counts. Source after
# `set -Eeuo pipefail`.
# shellcheck shell=bash

_lib_self_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_self_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_self_dir=.; fi
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_self_dir}/ascii-match.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_self_dir}/enumerate.sh"

# @description Run `fn <name> <slot>` for every name, at most
# `CHECK_WORKERS_OVERRIDE` (default `nproc`) at a time, with
# `slot="<result_dir>/<index>"` and the index zero-padded in roster order.
# The function's stdout and stderr go to `<slot>.out`; the helper writes
# `<slot>.name`, `<slot>.rc` and `<slot>.secs` and prints
# `done: <name> pass` or `done: <name> FAIL` as each run finishes. The
# function may write further files at `<slot>.<ext>`. A failing run never
# stops the batch. The status files, not the function's own reporting,
# decide the verdict, so a function that reports nothing cannot pass
# silently: it passes only by exiting 0.
# @arg $1 name of a shell function in the caller's scope
# @arg $2 result directory, existing and owned by the caller
# @arg $@ the names, in roster order
# @exitcode 0 every run exited 0
# @exitcode 1 at least one run exited non-zero
# @exitcode 2 (exit, not return) the worker count is not a positive
#   integer, or there are no names
function run_parallel() {
  local -r fn="$1" result_dir="$2"
  shift 2
  local workers="${CHECK_WORKERS_OVERRIDE:-}"
  if [[ -z ${workers} ]]; then
    workers="$(nproc)"
  fi
  if ! ascii_match "${workers}" '^[1-9][0-9]*$'; then
    printf 'run_parallel: CHECK_WORKERS_OVERRIDE must be a positive integer, got: %s\n' "${workers}" >&2
    exit 2
  fi
  if (($# == 0)); then
    printf 'run_parallel: no entries to run\n' >&2
    exit 2
  fi

  local name slot index=0 running=0 start rc
  for name in "$@"; do
    while ((running >= workers)); do
      wait -n || true
      running=$((running - 1))
    done
    slot="$(printf '%s/%03d' "${result_dir}" "${index}")"
    (
      start="$(date +%s)"
      rc=0
      # The function runs in a subshell of its own: an `exit` inside it then
      # returns here as a status, instead of ending this worker before the
      # status files below exist, which the verdict would read as a pass.
      ("${fn}" "${name}" "${slot}") >"${slot}.out" 2>&1 || rc=$?
      printf '%s\n' "${name}" >"${slot}.name"
      printf '%d\n' "${rc}" >"${slot}.rc"
      printf '%d\n' "$(($(date +%s) - start))" >"${slot}.secs"
      if [[ ${rc} -eq 0 ]]; then
        printf 'done: %s pass\n' "${name}"
      else
        printf 'done: %s FAIL\n' "${name}"
      fi
    ) &
    running=$((running + 1))
    index=$((index + 1))
  done
  wait

  # The verdict is read back from the status files rather than kept in a
  # counter the subshells cannot update, and through the guarded glob so
  # a result directory with no status file at all is a could-not-run.
  local -a rc_files=()
  glob_into rc_files 'run_parallel status files' "${result_dir}/*.rc"
  local f
  for f in "${rc_files[@]}"; do
    if [[ "$(<"${f}")" != 0 ]]; then
      return 1
    fi
  done
  return 0
}
