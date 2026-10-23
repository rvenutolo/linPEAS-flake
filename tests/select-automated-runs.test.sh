#!/usr/bin/env bash
# tests/select-automated-runs.test.sh
#
# Candidate-selection matrix for scripts/select-automated-runs.sh, the
# rule set the CI watchdog's automated sweep applies before it
# classifies anything. Offline and deterministic: each scenario is a
# run list written to a temporary directory, and the whole candidate
# list is compared, so a run that leaks in fails as surely as one that
# goes missing.
#
# The rows that matter most: a newer `skipped` run never hides an older
# failure, and `workflow_run` runs are each candidates on their own,
# because a workflow gated off on most triggers would otherwise bury
# every real failure under its skipped runs; and the lookback is read
# from `updated_at`, so a run created before it whose latest attempt
# finished inside it stays a candidate.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/select-automated-runs.sh"

TMP_DIR="$(mktemp --directory)"
readonly TMP_DIR
trap 'rm --recursive --force -- "${TMP_DIR}"' EXIT

failures=0

# @description One run object. Fields default to a completed failed push
# run on main of workflow 1.
# @arg $1 id  @arg $2 workflow_id  @arg $3 event  @arg $4 created_at
# @arg $5 status  @arg $6 conclusion (`null` for none)
# @arg $7 head_branch (default main)  @arg $8 path (default wf<workflow_id>)
# @arg $9 updated_at (default created_at)
function run() {
  local -r id="$1" wf="$2" event="$3" created="$4" status="$5" conclusion="$6"
  local -r branch="${7:-main}" path="${8:-.github/workflows/wf$2.yml}" updated="${9:-$4}"
  local concl_json='null'
  if [[ ${conclusion} != 'null' ]]; then
    concl_json="\"${conclusion}\""
  fi
  printf '{"id":%s,"workflow_id":%s,"event":"%s","created_at":"%s","updated_at":"%s","status":"%s","conclusion":%s,"head_branch":"%s","path":"%s"}' \
    "${id}" "${wf}" "${event}" "${created}" "${updated}" "${status}" "${concl_json}" "${branch}" "${path}"
}

# @arg $1 description  @arg $2 expected ids, comma-separated ('' for none)
# remaining args: run objects
function expect_ids() {
  local -r desc="$1" want="$2"
  shift 2
  local input="${TMP_DIR}/${desc// /-}.json" out rc=0
  local IFS=','
  printf '[%s]' "$*" >"${input}"
  out="$(bash "${SCRIPT}" --updated-since "${SINCE}" <"${input}" 2>&1)" || rc=$?
  local got
  got="$(printf '%s' "${out}" | tr '\n' ',')"
  got="${got%,}"
  if [[ ${rc} -ne 0 || ${got} != "${want}" ]]; then
    printf 'FAIL %s: exit %d, ids %q, want exit 0, ids %q\n' "${desc}" "${rc}" "${got}" "${want}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${desc}"
}

# @arg $1 description  @arg $2 expected exit code  @arg $3 stdin text
# remaining args: passed through
function expect_exit() {
  local -r desc="$1" want_rc="$2" text="$3"
  shift 3
  local rc=0
  printf '%s' "${text}" >"${TMP_DIR}/bad.json"
  bash "${SCRIPT}" "$@" <"${TMP_DIR}/bad.json" >/dev/null 2>&1 || rc=$?
  if [[ ${rc} -ne ${want_rc} ]]; then
    printf 'FAIL %s: exit %d, want %d\n' "${desc}" "${rc}" "${want_rc}" >&2
    failures=1
    return
  fi
  printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
}

# SINCE is the lookback cutoff every expect_ids row passes; T0 is before
# it, T1 to T3 after it.
readonly SINCE='2026-01-01T00:30:00Z'
readonly T0='2025-12-30T00:00:00Z' T1='2026-01-01T01:00:00Z' T2='2026-01-01T02:00:00Z' T3='2026-01-01T03:00:00Z'

# --- push and schedule: the newest run of a workflow per event --------
expect_ids "newest failed push is a candidate" 1 \
  "$(run 1 1 push "${T2}" completed failure)" \
  "$(run 2 1 push "${T1}" completed success)"
expect_ids "newer successful push replaces a failure" '' \
  "$(run 1 1 push "${T1}" completed failure)" \
  "$(run 2 1 push "${T2}" completed success)"
expect_ids "newer in-progress push replaces a failure" '' \
  "$(run 1 1 push "${T1}" completed failure)" \
  "$(run 2 1 push "${T2}" in_progress null)"
expect_ids "newer skipped push does not replace a failure" 1 \
  "$(run 1 1 push "${T1}" completed failure)" \
  "$(run 2 1 push "${T2}" completed skipped)"
expect_ids "newer skipped schedule does not replace a failure" 3 \
  "$(run 3 2 schedule "${T1}" completed timed_out)" \
  "$(run 4 2 schedule "${T2}" completed skipped)"
expect_ids "push and schedule of one workflow are separate keys" 5,6 \
  "$(run 5 3 push "${T1}" completed failure)" \
  "$(run 6 3 schedule "${T2}" completed cancelled)"
expect_ids "a newer push of another workflow replaces nothing" 7 \
  "$(run 7 4 push "${T1}" completed failure)" \
  "$(run 8 5 push "${T2}" completed success)"

# --- workflow_run: every failed run on its own ------------------------
expect_ids "workflow_run failure survives newer skipped runs" 10 \
  "$(run 10 6 workflow_run "${T1}" completed failure renovate/a)" \
  "$(run 11 6 workflow_run "${T2}" completed skipped renovate/b)" \
  "$(run 12 6 workflow_run "${T3}" completed skipped main)"
expect_ids "workflow_run failure survives a newer success" 13 \
  "$(run 13 6 workflow_run "${T1}" completed failure renovate/a)" \
  "$(run 14 6 workflow_run "${T2}" completed success renovate/b)"
expect_ids "two workflow_run failures are both candidates" 15,16 \
  "$(run 15 6 workflow_run "${T1}" completed failure renovate/a)" \
  "$(run 16 6 workflow_run "${T2}" completed cancelled renovate/b)"
expect_ids "in-progress workflow_run run is not a candidate" '' \
  "$(run 17 6 workflow_run "${T1}" in_progress null renovate/a)"

# --- lookback: the latest attempt's finish, not the run's creation -----
expect_ids "created before the lookback, updated inside it, is a candidate" 30 \
  "$(run 30 13 schedule "${T0}" completed failure main '' "${T2}")"
expect_ids "updated before the lookback is dropped" '' \
  "$(run 31 14 schedule "${T0}" completed failure main '' "${T0}")"
expect_ids "updated exactly at the cutoff is a candidate" 32 \
  "$(run 32 15 workflow_run "${T0}" completed failure renovate/a '' "${SINCE}")"
expect_ids "a newer run outside the lookback still replaces an older one" '' \
  "$(run 34 16 push "${T0}" completed success main '' "${T0}")" \
  "$(run 35 16 push '2025-12-29T00:00:00Z' completed failure main '' "${T1}")"

# --- out of scope ------------------------------------------------------
expect_ids "push off main is not covered" '' \
  "$(run 20 7 push "${T1}" completed failure feature)"
expect_ids "a push off main replaces nothing on main" 21 \
  "$(run 21 7 push "${T1}" completed failure main)" \
  "$(run 22 7 push "${T2}" completed success feature)"
expect_ids "workflow_dispatch and pull_request are not covered" '' \
  "$(run 23 8 workflow_dispatch "${T1}" completed failure)" \
  "$(run 24 8 pull_request "${T1}" completed failure feature)"
expect_ids "the watchdog's own runs are not covered" '' \
  "$(run 25 9 schedule "${T1}" completed failure main .github/workflows/ci-watchdog.yml)"
expect_ids "success, skipped and neutral are not candidates" '' \
  "$(run 26 10 schedule "${T1}" completed success)" \
  "$(run 27 11 schedule "${T1}" completed skipped)" \
  "$(run 28 12 schedule "${T1}" completed neutral)"
expect_ids "an empty list has no candidates" ''

# --- operational errors -------------------------------------------------
# A malformed payload is a could-not-run, never an empty selection.
expect_exit "malformed JSON payload" 2 'not json' --updated-since "${SINCE}"
expect_exit "a payload that is an object, not an array" 2 '{}' --updated-since "${SINCE}"
expect_exit "a payload run missing workflow_id" 2 '[{"id":1,"event":"push","path":"p","head_branch":"main","created_at":"x","updated_at":"2026-01-01T01:00:00Z","status":"completed","conclusion":"failure"}]' --updated-since "${SINCE}"
expect_exit "a payload run missing updated_at" 2 '[{"id":1,"workflow_id":1,"event":"push","path":"p","head_branch":"main","created_at":"x","status":"completed","conclusion":"failure"}]' --updated-since "${SINCE}"
expect_exit "a payload run whose updated_at carries milliseconds" 2 '[{"id":1,"workflow_id":1,"event":"push","path":"p","head_branch":"main","created_at":"x","updated_at":"2026-01-01T01:00:00.000Z","status":"completed","conclusion":"failure"}]' --updated-since "${SINCE}"
expect_exit "no --updated-since" 2 '[]'
expect_exit "an --updated-since with milliseconds" 2 '[]' --updated-since '2026-01-01T00:30:00.000Z'
expect_exit "an extra argument" 2 '[]' --updated-since "${SINCE}" --extra

if [[ ${failures} -ne 0 ]]; then
  printf '\nselect-automated-runs: FAILURES\n' >&2
  exit 1
fi
printf '\nselect-automated-runs: all passed\n'
