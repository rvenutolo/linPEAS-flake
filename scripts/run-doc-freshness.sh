#!/usr/bin/env bash
# scripts/run-doc-freshness.sh
#
# @description Run every doc-freshness regenerate-and-diff harness
# (tests/refresh-*.test.sh) in one devShell, printing a per-generator
# pass/fail summary table to stdout and $GITHUB_STEP_SUMMARY. Runs all
# harnesses even if one fails; exits 1 if any failed, 2 if none found.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

function main() {
  local -a harnesses=()
  local h
  # Sorted glob, filled through the shared helper so a scan root holding
  # no harness is a could-not-run rather than a run that found nothing.
  glob_into harnesses 'doc-freshness harnesses' "${TESTS_DIR}/refresh-*.test.sh"

  local failed=0
  local -a rows=()
  local name status start end secs rc
  for h in "${harnesses[@]}"; do
    name="$(basename "${h}")"
    rc=0
    start="$(date +%s)"
    bash "${h}" || rc=$?
    end="$(date +%s)"
    secs=$((end - start))
    if [[ ${rc} -eq 0 ]]; then
      status='pass'
    else
      status='FAIL'
      failed=1
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

# Emits the markdown summary table from main's `rows` (dynamic scope).
function emit_table() {
  printf '| harness | result | time |\n'
  printf '| --- | --- | --- |\n'
  # shellcheck disable=SC2154
  printf '%s\n' "${rows[@]}"
}

main "$@"
