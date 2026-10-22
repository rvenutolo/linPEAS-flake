#!/usr/bin/env bash
# tests/fetch-ci-run.test.sh
#
# Output shape and call discipline for scripts/fetch-ci-run.sh. A stub
# `gh` on PATH serves canned responses keyed on the API route and logs
# every call, so no scenario touches the network. The output must match
# the classifier's input contract: a null head_branch is coalesced to an
# empty string, annotations are fetched only for jobs that did not
# succeed, and an API failure is passed through as exit 1.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/fetch-ci-run.sh"
readonly CLASSIFIER="${REPO_ROOT}/scripts/classify-ci-run.sh"

failures=0

STUB_DIR="$(mktemp --directory)"
readonly STUB_DIR
CALL_LOG="${STUB_DIR}/calls.log"
readonly CALL_LOG
trap 'rm --force -- "${STUB_DIR}/gh" "${STUB_DIR}/calls.log" "${STUB_DIR}/out" "${STUB_DIR}/err" "${STUB_DIR}/outcome"; rmdir -- "${STUB_DIR}"' EXIT

# The stub emits what `gh api --jq` would print: the run object for the
# run route, one job object per line for the jobs route, and the message
# array for an annotations route. STUB_HEAD_BRANCH, STUB_FAIL_ROUTE and
# STUB_BAD_ROUTE (with STUB_BAD_BODY as its response) select the scenario.
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${STUB_CALL_LOG}"
case "$*" in
*"${STUB_FAIL_ROUTE:-__none__}"*)
  printf 'gh: HTTP 500 stub failure for %s\n' "${STUB_FAIL_ROUTE}" >&2
  exit 1
  ;;
*"${STUB_BAD_ROUTE:-__none__}"*)
  printf '%s\n' "${STUB_BAD_BODY}"
  ;;
*/check-runs/*/annotations*)
  if [[ -n ${STUB_ANN_RAW+set} ]]; then
    # Raw API body, run through the --jq program the fetcher passed.
    all_args="$*"
    jq --compact-output "${all_args#*--jq }" <<<"${STUB_ANN_RAW}"
    exit
  fi
  ;;&
*/check-runs/201/annotations*)
  printf '["The job has exceeded the maximum execution time of 30m0s"]\n'
  ;;
*/check-runs/202/annotations*)
  printf '["Canceling since a higher priority waiting request for ci-main exists"]\n'
  ;;
*/actions/runs/777/jobs*)
  printf '%s\n' '{"id":200,"name":"build","conclusion":"success","steps":[{"name":"Set up job","conclusion":"success"}]}'
  printf '%s\n' '{"id":201,"name":"lint","conclusion":"failure","steps":[{"name":"Run lint","conclusion":"cancelled"}]}'
  printf '%s\n' '{"id":202,"name":"docs","conclusion":"cancelled","steps":[]}'
  ;;
*/actions/runs/777\ *)
  printf '{"id":777,"name":"ci","path":".github/workflows/ci.yml","event":"pull_request","head_branch":%s,"run_attempt":2}\n' \
    "${STUB_HEAD_BRANCH:-\"feat/x\"}"
  ;;
*)
  printf 'stub: unexpected route %s\n' "$*" >&2
  exit 3
  ;;
esac
STUB
chmod +x "${STUB_DIR}/gh"

# @description Run the fetcher with the stub on PATH and record the
# scenario in the discrimination gate. Sets rc; stdout and stderr land in
# STUB_DIR/out and STUB_DIR/err.
# @arg $1 scenario name  @arg $2 expected exit code
# @arg $3 asserted substring of the stream named by $4
# @arg $4 stream, stdout or stderr
# remaining args: fetcher arguments
function run_scenario() {
  local -r name="$1" want_rc="$2" substring="$3" stream="$4"
  shift 4
  : >"${CALL_LOG}"
  rc=0
  PATH="${STUB_DIR}:${PATH}" STUB_CALL_LOG="${CALL_LOG}" \
    GH_TOKEN=stub GITHUB_REPOSITORY=owner/repo \
    bash "${SCRIPT}" "$@" >"${STUB_DIR}/out" 2>"${STUB_DIR}/err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${STUB_DIR}/outcome"
  harness_assert_record "${name}" "${substring}" \
    "${STUB_DIR}/outcome" "${STUB_DIR}/out" "${STUB_DIR}/err"
  if [[ ${rc} -ne ${want_rc} ]]; then
    fail "${name}: exit ${rc}, want ${want_rc}"
    sed 's/^/    /' "${STUB_DIR}/err" >&2
    return 1
  fi
  if ! grep --fixed-strings --quiet -- "${substring}" "${STUB_DIR}/${stream#std}"; then
    fail "${name}: ${stream} missing ${substring}"
    return 1
  fi
  printf 'OK   %s (exit %d)\n' "${name}" "${rc}"
}

# @description Record a failure.
# @arg $1 message
function fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=1
}

# @description Assert the last run's stdout equals expected JSON.
# @arg $1 description  @arg $2 expected JSON
function expect_json() {
  local want got
  want="$(printf '%s' "$2" | jq --sort-keys .)"
  got="$(jq --sort-keys . <"${STUB_DIR}/out")"
  if [[ ${got} != "${want}" ]]; then
    fail "$1: output differs"
    printf 'want:\n%s\ngot:\n%s\n' "${want}" "${got}" >&2
    return 1
  fi
  printf 'OK   %s\n' "$1"
}

readonly EXPECTED='{
  "id": 777, "name": "ci", "path": ".github/workflows/ci.yml",
  "event": "pull_request", "head_branch": "feat/x", "run_attempt": 2,
  "jobs": [
    {"id":200,"name":"build","conclusion":"success","steps":[{"name":"Set up job","conclusion":"success"}],"annotations":[]},
    {"id":201,"name":"lint","conclusion":"failure","steps":[{"name":"Run lint","conclusion":"cancelled"}],
      "annotations":["The job has exceeded the maximum execution time of 30m0s"]},
    {"id":202,"name":"docs","conclusion":"cancelled","steps":[],
      "annotations":["Canceling since a higher priority waiting request for ci-main exists"]}
  ]
}'

# --- happy path ------------------------------------------------------
if run_scenario "happy path" 0 '"head_branch": "feat/x"' stdout 777; then
  expect_json "happy-path output" "${EXPECTED}" || true
  if ! grep --fixed-strings --quiet -- '--paginate' "${CALL_LOG}"; then
    fail 'jobs call carried no --paginate'
  fi
  if ! grep --fixed-strings --quiet -- 'filter=latest' "${CALL_LOG}"; then
    fail 'jobs call did not ask for the latest attempt'
  fi
  if grep --fixed-strings --quiet -- 'check-runs/200/' "${CALL_LOG}"; then
    fail 'annotations fetched for the successful job'
  fi
  for id in 201 202; do
    if ! grep --fixed-strings --quiet -- "check-runs/${id}/annotations" "${CALL_LOG}"; then
      fail "annotations not fetched for job ${id}"
    fi
  done
  printf 'OK   call-log discipline\n'

  cls_rc=0
  cls_out="$(bash "${CLASSIFIER}" --policy bot-pr <"${STUB_DIR}/out" 2>&1)" || cls_rc=$?
  if [[ ${cls_rc} -ne 0 || ${cls_out%%$'\n'*} != 'retry' ]]; then
    fail "classifier rejected fetcher output: rc=${cls_rc} out=${cls_out}"
  else
    printf 'OK   classifier accepts the output\n'
  fi
fi

# --- null head_branch becomes an empty string ------------------------
# The classifier requires a string, and the API returns null for a run
# whose branch was deleted.
if STUB_HEAD_BRANCH=null run_scenario "null head_branch" 0 '"head_branch": ""' stdout 777; then
  if [[ "$(jq --raw-output '.head_branch | type' <"${STUB_DIR}/out")" != 'string' ]]; then
    fail 'null head_branch not coalesced to a string'
  fi
fi

# --- usage errors ----------------------------------------------------
run_scenario "non-numeric run id" 2 'invalid run id abc' stderr abc || true
run_scenario "missing run id" 2 'usage:' stderr || true

# --- API failures pass the gh error through --------------------------
STUB_FAIL_ROUTE='/jobs' run_scenario "jobs call fails" 1 \
  'could not fetch repos/owner/repo/actions/runs/777/jobs' stderr 777 || true
harness_assert_also 'stub failure for /jobs'
STUB_FAIL_ROUTE='/check-runs/' run_scenario "annotations call fails" 1 \
  'could not fetch annotations for job 201' stderr 777 || true
harness_assert_also 'stub failure for /check-runs/'

# --- a failed job with no annotations keeps an empty list -------------
# The stub serves the raw API body and applies the fetcher's own --jq
# program, so the program is what is under test.
if STUB_HEAD_BRANCH='"feat/empty-annotations"' STUB_ANN_RAW='[]' run_scenario "empty annotation list" 0 '"head_branch": "feat/empty-annotations"' stdout 777; then
  if [[ "$(jq --compact-output '[.jobs[] | select(.id == 201) | .annotations]' <"${STUB_DIR}/out")" != '[[]]' ]]; then
    fail 'a failed job with no annotations did not keep annotations as []'
  fi
fi

# --- malformed payloads are could-not-run (exit 2) ---------------------
# A malformed run payload: not JSON at all.
STUB_BAD_ROUTE='/runs/777 ' STUB_BAD_BODY='not json' \
  run_scenario "malformed run payload" 2 \
  'actions/runs/777 is not valid JSON' stderr 777 || true
# A malformed jobs payload: valid JSON whose job id is a string.
STUB_BAD_ROUTE='/jobs' STUB_BAD_BODY='{"id":"x","name":"a","conclusion":null,"steps":[]}' \
  run_scenario "malformed jobs payload" 2 \
  'a job .id is not a number' stderr 777 || true
# A malformed annotations payload: an object where an array belongs.
STUB_BAD_ROUTE='/check-runs/' STUB_BAD_BODY='{"oops":1}' \
  run_scenario "malformed annotations payload" 2 \
  'payload is object, want array' stderr 777 || true

harness_assert_verify || failures=1

if [[ ${failures} -ne 0 ]]; then
  printf '\nfetch-ci-run: FAILURES\n' >&2
  exit 1
fi
printf '\nfetch-ci-run: all passed\n'
