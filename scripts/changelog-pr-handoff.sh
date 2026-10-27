#!/usr/bin/env bash
# scripts/changelog-pr-handoff.sh
#
# @description Decide whether release-on-bump's changelog job may hand a
# changelog PR still open at its deadline to the CI watchdog. Reads the
# JSON of `gh pr view --json autoMergeRequest,mergeStateStatus,statusCheckRollup`
# on stdin and prints one line: `handoff` when the PR is in the shape the
# watchdog acts on, or `fail<TAB><reason>` when it is not, in which case
# the job fails and its notify job files.
#
# The watchdog acts only on a bot PR with auto-merge armed and a failed
# workflow run on its head, so all three of these must hold to hand off:
# auto-merge is armed (`autoMergeRequest` is not null); the merge state
# is not `BEHIND` (auto-merge never updates the branch, so the PR waits
# forever) or `DIRTY` (a conflict); and at least one check run on the
# head concluded `FAILURE`, `CANCELLED` or `TIMED_OUT`. The watchdog
# re-runs failures and timeout cancels, not a superseded or manual
# cancel, and a check run carries no annotation to tell those cancels
# apart, so every `CANCELLED` counts here: a PR whose only red check is a
# superseded or manual cancel is handed off and gets no watchdog action.
# A PR whose checks are all still pending or green past
# the deadline has nothing for the watchdog to re-run, and a required
# check that never started leaves no failed run at all, so both fail
# here rather than sit open with no issue. A hung check is cancelled by
# its own job timeout well inside the deadline, so it counts as failed.
# Commit status contexts are not counted: the watchdog re-runs workflow
# runs, and a status context has none.
#
# Usage:
#   gh pr view <n> --json autoMergeRequest,mergeStateStatus,statusCheckRollup \
#     | changelog-pr-handoff.sh
#
# Exit codes:
#   0  the decision was printed (a `fail` line is an answer, not this
#      script failing)
#   2  bad arguments, or input that is not the expected object

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

if [[ $# -ne 0 ]]; then
  printf 'usage: gh pr view <n> --json autoMergeRequest,mergeStateStatus,statusCheckRollup | %s\n' "${0##*/}" >&2
  exit 2
fi
require_tool jq

PR_JSON="$(cat)"
readonly PR_JSON

# jq exits 5 on malformed input and 1 when the shape check is false;
# both are bad input.
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly SHAPE_PROGRAM='
  (type == "object")
  and ((.autoMergeRequest | type) as $t | $t == "object" or $t == "null")
  and (.mergeStateStatus | type == "string")
  and (.statusCheckRollup | type == "array")
  and all(.statusCheckRollup[];
    (type == "object")
    and (.__typename | type == "string")
    and ((.conclusion | type) as $t | $t == "string" or $t == "null"))'
if ! printf '%s' "${PR_JSON}" | jq --exit-status "${SHAPE_PROGRAM}" >/dev/null 2>&1; then
  printf 'input is not a gh pr view object with autoMergeRequest, mergeStateStatus and statusCheckRollup\n' >&2
  exit 2
fi

# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly DECIDE_PROGRAM='
  [ .statusCheckRollup[]
    | select(.__typename == "CheckRun")
    | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT") ]
    as $failed
  | if .autoMergeRequest == null then "fail\tauto-merge is not armed"
    elif .mergeStateStatus == "BEHIND" then "fail\tthe PR is behind main, and auto-merge never updates the branch"
    elif .mergeStateStatus == "DIRTY" then "fail\tthe PR conflicts with main"
    elif ($failed | length) == 0 then "fail\tno check on the PR head failed, so the CI watchdog has nothing to re-run"
    else "handoff" end'

printf '%s' "${PR_JSON}" | jq --raw-output "${DECIDE_PROGRAM}"
