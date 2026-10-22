#!/usr/bin/env bash
# scripts/classify-ci-run.sh
#
# @description Classify one GitHub Actions run's jobs into a retry
# verdict. Reads the run JSON on stdin (id, name, path, event,
# head_branch, run_attempt, and jobs each carrying conclusion, steps and
# annotations) and prints a verdict line, `retry`, `exhausted`, `report`
# or `ignore`, followed by one `<job>\t<class>\t<reason>` line for every
# job that failed, was cancelled or timed out. `class` is `transient`
# (infrastructure, worth a rerun), `real` (a step of the job's own work
# failed) or `superseded` (cancelled by a newer run, never counted).
# Pure and side-effect free so the decision is unit-testable without a
# workflow run.
#
# Usage:
#   classify-ci-run.sh --policy bot-pr|automated < run.json
#   classify-ci-run.sh --print-max-attempts
#
# Policies. `bot-pr` retries any counted job until the attempt cap,
# because a bot PR has no human watching a red check. `automated`
# retries only runs the repo triggers itself (schedule, workflow_run,
# push to main) and only when every counted job is transient, so a real
# regression is reported on the first attempt rather than retried.
# Other events report without retrying: a person started them and can
# rerun them.
#
# A job that fails before its own work starts (runner setup, checkout,
# the setup-nix action) is transient. A failed step after those is real,
# including `Post` steps. A failure with no failed step has nothing to
# blame the repo for and is transient.
#
# Exit codes:
#   0  classified (a `report` or `exhausted` verdict is an answer, not
#      this script failing)
#   2  bad arguments, or input that is not a run object with a `jobs`
#      array of the expected shape

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

readonly MAX_ATTEMPTS=3

# A failed step whose name starts with one of these ran before the job's
# own work, so the failure is the platform's, not the repo's.
readonly SETUP_PREFIXES=(
  'Set up job'
  'Pre Run step-security/harden-runner@'
  'Run step-security/harden-runner@'
  'Run actions/checkout@'
  'Run ./.github/actions/setup-nix'
  'Run actions/create-github-app-token@'
)

function usage() {
  printf 'usage: %s --policy bot-pr|automated < run.json\n' "${0##*/}" >&2
  printf '       %s --print-max-attempts\n' "${0##*/}" >&2
  exit 2
}

if [[ $# -eq 1 && $1 == '--print-max-attempts' ]]; then
  printf '%s\n' "${MAX_ATTEMPTS}"
  exit 0
fi
if [[ $# -ne 2 || $1 != '--policy' ]]; then
  usage
fi
readonly POLICY="$2"
require_tool jq
case "${POLICY}" in
bot-pr | automated) ;;
*)
  printf 'invalid policy %q (want bot-pr|automated)\n' "${POLICY}" >&2
  exit 2
  ;;
esac

RUN_JSON="$(cat)"
readonly RUN_JSON

# jq exits 5 on malformed input and 1 when the shape check is false;
# both are bad input.
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly SHAPE_PROGRAM='
  (type == "object")
  and (.event | type == "string")
  and (.head_branch | type == "string")
  and (.run_attempt | type == "number")
  and (.jobs | type == "array")
  and all(.jobs[];
    (type == "object")
    and (.name | type == "string")
    and ((.conclusion | type) as $t | $t == "string" or $t == "null")
    and (.steps | type == "array")
    and all(.steps[]; (.name | type == "string") and ((.conclusion | type) as $t | $t == "string" or $t == "null"))
    and (.annotations | type == "array")
    and all(.annotations[]; type == "string"))'
if ! printf '%s' "${RUN_JSON}" | jq --exit-status "${SHAPE_PROGRAM}" >/dev/null 2>&1; then
  printf 'input is not a run object with the expected jobs shape\n' >&2
  exit 2
fi

SETUP_PREFIXES_JSON="$(printf '%s\n' "${SETUP_PREFIXES[@]}" | jq --raw-input . | jq --slurp --compact-output .)"
readonly SETUP_PREFIXES_JSON

# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly CLASSIFY_PROGRAM='
  def anns: .annotations;
  .jobs[]
  | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")
  | . as $job
  | (
      if .conclusion == "timed_out" then ["transient", "timed_out"]
      elif any(anns[]; startswith("The job has exceeded the maximum execution time")) then ["transient", "timeout"]
      elif .conclusion == "cancelled" then
        if any(anns[]; startswith("Canceling since a higher priority waiting request"))
        then ["superseded", "superseded"]
        else ["superseded", "cancelled-other"] end
      elif any(anns[]; contains("lost communication with the server")
        or contains("The runner has received a shutdown signal")) then ["transient", "runner-lost"]
      else
        ([.steps[] | select(.conclusion == "failure")] | first) as $step
        | if $step == null then ["transient", "no-failed-step"]
          elif any($prefixes[]; . as $p | $step.name | startswith($p))
          then ["transient", "setup-step:" + $step.name]
          else ["real", "step:" + $step.name] end
      end
    )
  | [$job.name, .[0], .[1]] | join("\t")'

classified="$(printf '%s' "${RUN_JSON}" | jq --raw-output --argjson prefixes "${SETUP_PREFIXES_JSON}" "${CLASSIFY_PROGRAM}")"

transient=0
real=0
if [[ -n ${classified} ]]; then
  while IFS=$'\t' read -r _ job_class _; do
    case "${job_class}" in
    transient) transient=$((transient + 1)) ;;
    real) real=$((real + 1)) ;;
    *) ;;
    esac
  done <<<"${classified}"
fi

event="$(printf '%s' "${RUN_JSON}" | jq --raw-output '.event')"
head_branch="$(printf '%s' "${RUN_JSON}" | jq --raw-output '.head_branch')"
run_attempt="$(printf '%s' "${RUN_JSON}" | jq --raw-output '.run_attempt')"

verdict='ignore'
if ((transient + real > 0)); then
  eligible=true
  if [[ ${POLICY} == 'automated' ]]; then
    case "${event}" in
    schedule | workflow_run) ;;
    push) [[ ${head_branch} == 'main' ]] || eligible=false ;;
    *) eligible=false ;;
    esac
  fi
  if [[ ${eligible} == 'false' ]] || { [[ ${POLICY} == 'automated' ]] && ((real > 0)); }; then
    verdict='report'
  elif ((run_attempt < MAX_ATTEMPTS)); then
    verdict='retry'
  else
    verdict='exhausted'
  fi
fi

printf '%s\n' "${verdict}"
if [[ -n ${classified} ]]; then
  printf '%s\n' "${classified}"
fi
