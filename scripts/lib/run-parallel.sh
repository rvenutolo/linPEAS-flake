#!/usr/bin/env bash
# scripts/lib/run-parallel.sh
#
# @description Sourced helper. run_parallel runs an ordered list of
# `label|command` jobs with bounded concurrency (xargs -P), capturing each
# job's output/exit/duration, then replays output in original order and
# emits a markdown pass/fail/timing table to stdout and $GITHUB_STEP_SUMMARY.
# Runs all jobs even if some fail; returns non-zero iff any job failed.
#
# Usage: run_parallel <jobs_array_name> <header_word> <summary_title>
#   jobs entries: "label|command" — split on the FIRST pipe; command may
#   contain pipes; label may not. Concurrency = ${RUN_PARALLEL_JOBS:-nproc},
#   clamped to [1, job-count].

# shellcheck shell=bash

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  printf 'run-parallel.sh requires bash 4.3+ (namerefs)\n' >&2
  exit 1
fi

# Internal: executes one job by index. Reads command from
# ${RP_TMPDIR}/<idx>.cmd; writes <idx>.out (stdout+stderr), <idx>.rc, <idx>.t.
# Exported for the xargs subshell.
function _rp_run_one() {
  local -r idx="$1"
  local start end rc=0
  start="$(date +%s)"
  bash "${RP_TMPDIR}/${idx}.cmd" >"${RP_TMPDIR}/${idx}.out" 2>&1 || rc=$?
  end="$(date +%s)"
  printf '%d' "${rc}" >"${RP_TMPDIR}/${idx}.rc"
  printf '%d' "$((end - start))" >"${RP_TMPDIR}/${idx}.t"
}
export -f _rp_run_one

function run_parallel() {
  local -n _jobs_ref="$1"
  local -r header="$2" title="$3"
  local -r count="${#_jobs_ref[@]}"

  local n="${RUN_PARALLEL_JOBS:-$(nproc)}"
  ((n > count)) && n="${count}"
  ((n < 1)) && n=1

  RP_TMPDIR="$(mktemp -d)"
  export RP_TMPDIR
  trap 'rm --recursive --force -- "${RP_TMPDIR}"' RETURN

  local i entry
  for ((i = 0; i < count; i++)); do
    entry="${_jobs_ref[i]}"
    printf '%s' "${entry#*|}" >"${RP_TMPDIR}/${i}.cmd"
    printf '%s' "${entry%%|*}" >"${RP_TMPDIR}/${i}.label"
  done

  # Dispatch. xargs returns 123 if any worker exits non-zero; the
  # authoritative status is the per-index .rc files, so ignore it.
  if ((count > 0)); then
    printf '%s\n' "$(seq 0 $((count - 1)))" |
      xargs -P "${n}" -I{} bash -c '_rp_run_one "$@"' _ {} || true
  fi

  local failed=0 label rc secs status
  local -a rows=()
  for ((i = 0; i < count; i++)); do
    label="$(cat "${RP_TMPDIR}/${i}.label")"
    rc="$(cat "${RP_TMPDIR}/${i}.rc" 2>/dev/null || echo 1)"
    secs="$(cat "${RP_TMPDIR}/${i}.t" 2>/dev/null || echo 0)"
    cat "${RP_TMPDIR}/${i}.out" 2>/dev/null || true
    if [[ ${rc} -eq 0 ]]; then
      status='pass'
    else
      status='FAIL'
      failed=1
    fi
    rows+=("$(printf '| %s | %s | %ds |' "${label}" "${status}" "${secs}")")
  done

  _rp_emit_table "${header}" rows
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      printf '### %s\n\n' "${title}"
      _rp_emit_table "${header}" rows
    } >>"${GITHUB_STEP_SUMMARY}"
  fi

  return "${failed}"
}

# Emits the markdown table. $1 header word; $2 name of the rows array.
function _rp_emit_table() {
  local -r header="$1"
  local -n _rows_ref="$2"
  printf '| %s | result | time |\n' "${header}"
  printf '| --- | --- | --- |\n'
  if ((${#_rows_ref[@]} > 0)); then
    printf '%s\n' "${_rows_ref[@]}"
  fi
}
