#!/usr/bin/env bash
# scripts/run-harness-group.sh
#
# @description Run every setup-tax failure-mode harness in one devShell,
# printing a per-harness pass/fail summary table to stdout and
# $GITHUB_STEP_SUMMARY. Runs all harnesses even if one fails; exits 1
# if any failed.

# Harness details: ratchet-pin-audit runs its test then its live enforce
# script (safe on PR). allowed-actions-api and settings-posture need
# admin-scoped App tokens and run schedule-only in their own drift-check
# workflows, so here they run test-only (no enforce script).

set -Eeuo pipefail
IFS=$'\n\t'

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"

# name | test-harness (under TESTS_DIR) | enforce-script (under
# SCRIPTS_DIR; empty = test-only). Pipe-delimited; no field contains a
# pipe or whitespace.
readonly -a HARNESSES=(
  'ratchet-pin-audit|check-ratchet-pin-audit.test.sh|check-ratchet-pin-audit.sh'
  'allowed-actions-api|check-allowed-actions-api.test.sh|'
  'settings-posture|check-settings-posture.test.sh|'
  'backfill-image-mode|classify-backfill-image-mode.test.sh|'
)

function main() {
  local failed=0
  local -a rows=()
  local entry name test_rel enforce_rel start end secs status rc
  for entry in "${HARNESSES[@]}"; do
    IFS='|' read -r name test_rel enforce_rel <<<"${entry}"
    rc=0
    start="$(date +%s)"
    if [[ ! -f "${TESTS_DIR}/${test_rel}" ]]; then
      printf '::error::missing test harness: %s/%s\n' "${TESTS_DIR}" "${test_rel}" >&2
      rc=1
    else
      bash "${TESTS_DIR}/${test_rel}" || rc=$?
      if [[ ${rc} -eq 0 && -n ${enforce_rel} ]]; then
        bash "${SCRIPTS_DIR}/${enforce_rel}" || rc=$?
      fi
    fi
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
      printf '### harness-group\n\n'
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
