#!/usr/bin/env bash
# tests/changelog-pr-handoff.test.sh
#
# Decision matrix for scripts/changelog-pr-handoff.sh, which decides
# whether release-on-bump's changelog job hands a changelog PR still
# open at its deadline to the CI watchdog. Offline and deterministic:
# each scenario is a `gh pr view` object written to a temporary
# directory, shaped as gh prints it (`__typename`, upper-case
# `conclusion` values, an empty `conclusion` for a pending check run and
# a null one for a status context), and the whole printed line is
# compared.
#
# The rows that matter most: a PR that is behind main, or whose checks
# are all pending or green, fails rather than hand off, because the
# watchdog acts only on a failed run and would leave either PR open with
# no issue.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/changelog-pr-handoff.sh"

TMP_DIR="$(mktemp --directory)"
readonly TMP_DIR
trap 'rm --recursive --force -- "${TMP_DIR}"' EXIT

failures=0

readonly ARMED='{"enabledAt":"2026-01-01T00:00:00Z","mergeMethod":"MERGE"}'

# @description One check run as gh prints it.
# @arg $1 name  @arg $2 conclusion ('' while pending)
function check_run() {
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":"%s"}' \
    "$1" "$([[ -n $2 ]] && printf COMPLETED || printf IN_PROGRESS)" "$2"
}

# @description One commit status context as gh prints it.
# @arg $1 context  @arg $2 state
function status_context() {
  printf '{"__typename":"StatusContext","context":"%s","state":"%s","conclusion":null}' "$1" "$2"
}

# @arg $1 autoMergeRequest JSON  @arg $2 mergeStateStatus
# remaining args: rollup entries
function pr() {
  local -r auto="$1" state="$2"
  shift 2
  local IFS=','
  printf '{"autoMergeRequest":%s,"mergeStateStatus":"%s","statusCheckRollup":[%s]}' "${auto}" "${state}" "$*"
}

# @arg $1 description  @arg $2 expected line  @arg $3 input JSON
function expect_line() {
  local -r desc="$1" want="$2"
  local -r input="${TMP_DIR}/${desc// /-}.json"
  local out rc=0
  printf '%s' "$3" >"${input}"
  out="$(bash "${SCRIPT}" <"${input}" 2>&1)" || rc=$?
  if [[ ${rc} -ne 0 || ${out} != "${want}" ]]; then
    printf 'FAIL %s: exit %d, printed %q, want exit 0, %q\n' "${desc}" "${rc}" "${out}" "${want}" >&2
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

readonly NOTHING_FAILED=$'fail\tno check on the PR head failed, so the CI watchdog has nothing to re-run'

# --- hand off: armed, mergeable, and a failed check to re-run ---------
expect_line "armed, blocked, one failed check hands off" 'handoff' \
  "$(pr "${ARMED}" BLOCKED "$(check_run build SUCCESS)" "$(check_run lint FAILURE)")"
expect_line "a timeout-cancelled check hands off" 'handoff' \
  "$(pr "${ARMED}" BLOCKED "$(check_run editorconfig CANCELLED)" "$(check_run build '')")"
expect_line "a timed_out check hands off" 'handoff' \
  "$(pr "${ARMED}" UNSTABLE "$(check_run build TIMED_OUT)")"
expect_line "unknown merge state with a failed check hands off" 'handoff' \
  "$(pr "${ARMED}" UNKNOWN "$(check_run build FAILURE)")"

# --- fail: the watchdog would never act ------------------------------
expect_line "auto-merge not armed fails" $'fail\tauto-merge is not armed' \
  "$(pr null BLOCKED "$(check_run build FAILURE)")"
expect_line "behind main fails even with a failed check" \
  $'fail\tthe PR is behind main, and auto-merge never updates the branch' \
  "$(pr "${ARMED}" BEHIND "$(check_run build FAILURE)")"
expect_line "a conflict fails" $'fail\tthe PR conflicts with main' \
  "$(pr "${ARMED}" DIRTY "$(check_run build FAILURE)")"
expect_line "checks still pending fails" "${NOTHING_FAILED}" \
  "$(pr "${ARMED}" BLOCKED "$(check_run build SUCCESS)" "$(check_run editorconfig '')")"
expect_line "a required check that never started fails" "${NOTHING_FAILED}" \
  "$(pr "${ARMED}" BLOCKED "$(check_run build SUCCESS)")"
expect_line "skipped and neutral checks are not failures" "${NOTHING_FAILED}" \
  "$(pr "${ARMED}" BLOCKED "$(check_run notify SKIPPED)" "$(check_run x NEUTRAL)")"
expect_line "a failed status context is not a failed run" "${NOTHING_FAILED}" \
  "$(pr "${ARMED}" BLOCKED "$(status_context ext FAILURE)")"
expect_line "an empty rollup fails" "${NOTHING_FAILED}" \
  "$(pr "${ARMED}" BLOCKED)"

# --- operational errors -------------------------------------------------
# A malformed payload is a could-not-run, never a decision.
expect_exit "malformed JSON payload" 2 'not json'
expect_exit "a payload that is an array" 2 '[]'
expect_exit "a payload missing mergeStateStatus" 2 '{"autoMergeRequest":null,"statusCheckRollup":[]}'
expect_exit "a rollup entry without __typename" 2 '{"autoMergeRequest":null,"mergeStateStatus":"CLEAN","statusCheckRollup":[{"conclusion":"FAILURE"}]}'
expect_exit "an argument" 2 '{}' --extra

if [[ ${failures} -ne 0 ]]; then
  printf '\nchangelog-pr-handoff: FAILURES\n' >&2
  exit 1
fi
printf '\nchangelog-pr-handoff: all passed\n'
