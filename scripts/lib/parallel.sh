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
# `slot="<result_dir>/<index>"` and the index zero-padded to three digits
# in roster order. A batch holds at most 999 names, which keeps every
# index inside three digits with one to spare, so the slots sort in roster
# order.
# The function's stdout and stderr go to `<slot>.out`; the worker writes
# `<slot>.name`, `<slot>.rc` and `<slot>.secs` from its EXIT trap and
# prints `done: <name> pass` or `done: <name> FAIL` as each run finishes.
# The function may write further files at `<slot>.<ext>`. Output that a
# process the function leaves running writes after the function returns
# still lands in `<slot>.out`, never in another entry's, but whatever
# arrives after the caller has replayed the slot is not shown. A failing run
# never stops the batch, and the batch's return says only that every
# entry recorded a status: the per-entry verdict is `<slot>.rc`, which
# the caller reads to build its rows. That split is what keeps errexit
# live inside the function: a call made in a `||` list or an `if` would
# have bash suspend `set -e` for everything under it, the function
# included, so a failing command in its middle would be ignored. Call
# this as a bare command, with errexit on, and read the slot files. A
# function that reports nothing cannot pass silently: it passes only by
# exiting 0, and a worker that dies before its trap runs is a
# could-not-run for the whole batch.
# @arg $1 name of a shell function in the caller's scope
# @arg $2 result directory, existing and owned by the caller
# @arg $@ the names, in roster order
# @exitcode 0 every entry ran and recorded a status
# @exitcode 2 (exit, not return) the worker count is not a positive
#   integer, there are no names or more than 999, or a worker left no
#   status file
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
  if (($# > 999)); then
    printf 'run_parallel: at most 999 entries, got %d\n' "$#" >&2
    exit 2
  fi

  local name slot index=0 running=0
  for name in "$@"; do
    while ((running >= workers)); do
      wait -n || true
      running=$((running - 1))
    done
    slot="$(printf '%s/%03d' "${result_dir}" "${index}")"
    (
      # The status is recorded by the EXIT trap rather than after the call:
      # with errexit live, a failing function ends this worker at once, and
      # the trap is what still runs. `$?` there is the status that ended
      # the worker, whether a failing command or an `exit` inside the
      # function.
      # The function gets a subshell of its own so that an `exit` inside
      # it ends that subshell, not this worker while the redirection is
      # still in force, which would send the progress line into the slot.
      # When a signal kills that subshell, this worker itself writes a job
      # message about it to its own stderr; the outer redirection sends
      # that message into the slot too, after the function's output,
      # rather than onto the runner's stream while runs are in flight.
      start="$(date +%s)"
      trap '_run_parallel_record "$?" "${name}" "${slot}" "${start}"' EXIT
      { ("${fn}" "${name}" "${slot}") >"${slot}.out" 2>&1; } 2>>"${slot}.out"
    ) &
    running=$((running + 1))
    index=$((index + 1))
  done
  wait

  # Every entry must have left a status; a worker killed before its trap
  # ran leaves none, and a batch read from the files that exist would be
  # one row short with nothing failed.
  local -a rc_files=()
  glob_into rc_files 'run_parallel status files' "${result_dir}/*.rc"
  if ((${#rc_files[@]} != $#)); then
    printf 'run_parallel: %d of %d entries left no status: a worker died before recording its result\n' \
      "$(($# - ${#rc_files[@]}))" "$#" >&2
    exit 2
  fi
}

# @description Write one entry's status files and progress line; the
# worker's EXIT trap.
# @arg $1 status  @arg $2 name  @arg $3 slot  @arg $4 start epoch seconds
function _run_parallel_record() {
  local -r rc="$1" name="$2" slot="$3" start="$4"
  printf '%s\n' "${name}" >"${slot}.name"
  printf '%d\n' "${rc}" >"${slot}.rc"
  printf '%d\n' "$(($(date +%s) - start))" >"${slot}.secs"
  if [[ ${rc} -eq 0 ]]; then
    printf 'done: %s pass\n' "${name}"
  else
    printf 'done: %s FAIL\n' "${name}"
  fi
}
