#!/usr/bin/env bash
# scripts/run-doc-freshness.sh
#
# @description Run every doc-freshness regenerate-and-diff harness
# (tests/refresh-*.test.sh) in one devShell, printing a per-generator
# pass/fail summary table to stdout and $GITHUB_STEP_SUMMARY. Harnesses
# run concurrently, at most CHECK_WORKERS_OVERRIDE (default nproc) at a
# time, with each one's output replayed in roster order once all have
# finished. Runs all harnesses even if one fails; exits 1 if any failed,
# 2 if none found.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/parallel.sh
source "${_lib_dir}/lib/parallel.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

function main() {
  local -a harnesses=()
  local h
  # Sorted glob, filled through the shared helper so a scan root holding
  # no harness is a could-not-run rather than a run that found nothing.
  glob_into harnesses 'doc-freshness harnesses' "${TESTS_DIR}/refresh-*.test.sh"

  local -a names=()
  for h in "${harnesses[@]}"; do
    names+=("$(basename "${h}")")
  done

  local results
  results="$(make_temp --directory)"
  # shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
  trap "rm --recursive --force -- '${results}'" EXIT

  local failed=0
  run_parallel run_one "${results}" "${names[@]}" || failed=1

  local -a rows=() name_files=()
  local name status secs rc slot
  glob_into name_files 'doc-freshness results' "${results}/*.name"
  for slot in "${name_files[@]}"; do
    slot="${slot%.name}"
    name="$(<"${slot}.name")"
    rc="$(<"${slot}.rc")"
    secs="$(<"${slot}.secs")"
    # payload-read-exempt: the slot file is this runner's own buffered copy of a check's stdout and stderr, replayed verbatim into the log; it is not a payload to parse, and a missing slot is already a could-not-run from glob_into above.
    cat -- "${slot}.out"
    if [[ ${rc} -eq 0 ]]; then
      status='pass'
    else
      status='FAIL'
    fi
    rows+=("$(printf '| %s | %s | %ds |' "${name}" "${status}" "${secs}")")
  done

  emit_table
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      printf '### doc-freshness\n\n'
      emit_table
    } >>"${GITHUB_STEP_SUMMARY}"
  fi

  exit "${failed}"
}

# Runs one harness by basename; invoked by `run_parallel`, which captures
# the output and status.
# @arg $1 harness basename  @arg $2 slot path (unused)
# shellcheck disable=SC2329 # invoked by name through run_parallel
function run_one() {
  bash "${TESTS_DIR}/$1"
}

# Emits the markdown summary table from main's `rows` (dynamic scope).
function emit_table() {
  printf '| harness | result | time |\n'
  printf '| --- | --- | --- |\n'
  # shellcheck disable=SC2154
  printf '%s\n' "${rows[@]}"
}

main "$@"
