#!/usr/bin/env bash
# scripts/select-automated-runs.sh
#
# @description Pick the runs the CI watchdog's automated sweep
# classifies. Reads a JSON array of workflow runs on stdin (each with
# id, workflow_id, path, event, head_branch, created_at, status and
# conclusion, as `listWorkflowRunsForRepo` returns them) and prints the
# id of every candidate, one per line, in ascending order. The caller
# bounds the array to the lookback window; this script applies the
# rest of the eligibility rules, so they are testable without a run.
#
# Rules. Only `push` runs on `main`, `schedule` runs and `workflow_run`
# runs are considered, and never the watchdog's own
# (`.github/workflows/ci-watchdog.yml`). A candidate is completed and
# concluded `failure`, `cancelled` or `timed_out`. A `push` or
# `schedule` run is a candidate only when it is the newest run of its
# workflow for its event, by `created_at`: a newer run, finished or
# still in progress, replaced it. A `workflow_run` run is a candidate
# on its own, because each is chained to a different upstream run (a
# different branch or commit) and a newer one replaces nothing. A
# `skipped` run never counts as replacing anything: a workflow whose
# jobs are all gated off by an `if:` concludes `skipped` on most
# triggers, and letting that hide an earlier failure would leave the
# failure with no retry and no issue.
#
# Usage:
#   select-automated-runs.sh < runs.json
#
# Exit codes:
#   0  the candidates were printed (possibly none)
#   2  bad arguments, or input that is not an array of run objects of
#      the expected shape

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

if [[ $# -ne 0 ]]; then
  printf 'usage: %s < runs.json\n' "${0##*/}" >&2
  exit 2
fi
require_tool jq

RUNS_JSON="$(cat)"
readonly RUNS_JSON

# jq exits 5 on malformed input and 1 when the shape check is false;
# both are bad input.
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly SHAPE_PROGRAM='
  (type == "array")
  and all(.[];
    (type == "object")
    and (.id | type == "number")
    and (.workflow_id | type == "number")
    and (.path | type == "string")
    and (.event | type == "string")
    and ((.head_branch | type) as $t | $t == "string" or $t == "null")
    and (.created_at | type == "string")
    and (.status | type == "string")
    and ((.conclusion | type) as $t | $t == "string" or $t == "null"))'
if ! printf '%s' "${RUNS_JSON}" | jq --exit-status "${SHAPE_PROGRAM}" >/dev/null 2>&1; then
  printf 'input is not an array of run objects with the expected shape\n' >&2
  exit 2
fi

# `created_at` is ISO 8601 in UTC with a `Z` suffix, so it sorts as a
# string; `max_by` keeps the last of equal keys, and `id` breaks a tie.
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly SELECT_PROGRAM='
  def failed: .status == "completed"
    and (.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out");
  [ .[]
    | select(.path != ".github/workflows/ci-watchdog.yml")
    | select(.conclusion != "skipped")
    | select((.event == "push" and .head_branch == "main")
        or .event == "schedule" or .event == "workflow_run") ]
  | ( [ .[] | select(.event == "workflow_run") | select(failed) ]
      + [ [ .[] | select(.event != "workflow_run") ]
          | group_by([.workflow_id, .event])[]
          | max_by([.created_at, .id])
          | select(failed) ] )
  | map(.id) | sort | .[]'

printf '%s' "${RUNS_JSON}" | jq --raw-output "${SELECT_PROGRAM}"
