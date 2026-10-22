#!/usr/bin/env bash
# scripts/fetch-ci-run.sh
#
# @description Fetch one GitHub Actions run's jobs, steps and annotations
# through `gh api` and print the JSON that scripts/classify-ci-run.sh
# reads on stdin: the run's id, name, path, event, head_branch (null
# becomes the empty string, which the classifier requires to be a
# string), run_attempt, and its latest attempt's jobs, each carrying id,
# name, conclusion, steps and annotations. Annotations are fetched only
# for jobs whose conclusion is failure, cancelled or timed_out; every
# other job carries an empty list.
#
# Usage:
#   GH_TOKEN=... GITHUB_REPOSITORY=owner/repo fetch-ci-run.sh <run_id>
#
# Exit codes:
#   0  the JSON was printed
#   1  an API call failed; the `gh` error is passed through on stderr
#   2  bad arguments, a missing tool, an unset environment variable, or an
#      API response that is not the JSON shape the reads below rely on

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_dir}/lib/ascii-match.sh"
# shellcheck source=scripts/lib/payload.sh
source "${_lib_dir}/lib/payload.sh"

readonly GH_API_VERSION_HEADER='X-GitHub-Api-Version: 2022-11-28'

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <run_id>\n' "${0##*/}" >&2
  exit 2
fi
readonly RUN_ID="$1"
if ! ascii_match "${RUN_ID}" '^[0-9]+$'; then
  printf 'invalid run id %q (want digits)\n' "${RUN_ID}" >&2
  exit 2
fi
require_tool gh
require_tool jq
if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
  printf 'GITHUB_REPOSITORY is not set\n' >&2
  exit 2
fi
readonly REPO_ROUTE="repos/${GITHUB_REPOSITORY}"

# A failed `gh api` already wrote its own error to stderr; the exit code
# here is the script's, not gh's.
if ! run_json="$(gh api --header "${GH_API_VERSION_HEADER}" \
  "${REPO_ROUTE}/actions/runs/${RUN_ID}" \
  --jq '{id, name, path, event, head_branch, run_attempt}')"; then
  log_err "could not fetch ${REPO_ROUTE}/actions/runs/${RUN_ID}"
  exit 1
fi

require_json_payload "${REPO_ROUTE}/actions/runs/${RUN_ID}" "${run_json}" '
  if type != "object" then "payload is \(type), want object"
  elif (.id | type) != "number" then ".id is \(.id | type), want number"
  elif (.name | type) != "string" then ".name is \(.name | type), want string"
  elif (.path | type) != "string" then ".path is \(.path | type), want string"
  elif (.event | type) != "string" then ".event is \(.event | type), want string"
  elif (.run_attempt | type) != "number" then ".run_attempt is \(.run_attempt | type), want number"
  else empty
  end'

# --paginate with --jq runs the program per page, so the result is one
# job object per line across every page.
if ! jobs_stream="$(gh api --paginate --header "${GH_API_VERSION_HEADER}" \
  "${REPO_ROUTE}/actions/runs/${RUN_ID}/jobs?filter=latest&per_page=100" \
  --jq '.jobs[] | {id, name, conclusion, steps: ((.steps // []) | map({name, conclusion}))}')"; then
  log_err "could not fetch ${REPO_ROUTE}/actions/runs/${RUN_ID}/jobs"
  exit 1
fi

if ! jobs_array="$(printf '%s\n' "${jobs_stream}" | jq --slurp --compact-output .)"; then
  printf 'payload from %s/actions/runs/%s/jobs is not valid JSON\n' "${REPO_ROUTE}" "${RUN_ID}" >&2
  exit 2
fi
require_json_payload "${REPO_ROUTE}/actions/runs/${RUN_ID}/jobs" "${jobs_array}" '
  if any(.[]; (.id | type) != "number") then "a job .id is not a number"
  elif any(.[]; (.name | type) != "string") then "a job .name is not a string"
  else empty
  end'

# Job id to annotation messages, for the jobs that did not succeed.
annotations_json='{}'
failed_ids="$(printf '%s' "${jobs_array}" | jq --raw-output '
  .[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out") | .id')"
if [[ -n ${failed_ids} ]]; then
  while IFS= read -r job_id; do
    if ! messages="$(gh api --header "${GH_API_VERSION_HEADER}" \
      "${REPO_ROUTE}/check-runs/${job_id}/annotations" \
      --jq '[.[] | (.message // "")]')"; then
      log_err "could not fetch annotations for job ${job_id}"
      exit 1
    fi
    require_json_payload "${REPO_ROUTE}/check-runs/annotations" "${messages}" '
      if type != "array" then "payload is \(type), want array"
      elif any(.[]; type != "string") then "an annotation message is not a string"
      else empty
      end'
    annotations_json="$(printf '%s' "${annotations_json}" |
      jq --compact-output --arg id "${job_id}" --argjson messages "${messages}" '.[$id] = $messages')"
  done <<<"${failed_ids}"
fi

# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
printf '%s' "${jobs_array}" | jq \
  --argjson run "${run_json}" --argjson annotations "${annotations_json}" '
  $run + {
    head_branch: ($run.head_branch // ""),
    jobs: map(. + {annotations: ($annotations[.id | tostring] // [])})
  }'
