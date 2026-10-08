#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-auto-merge-decline-gate.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/auto-merge-decline-gate"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good-gated.yml 0 ""
expect good-no-automerge.yml 0 ""
expect bad-no-gate.yml 1 "decline gate"
expect bad-partial.yml 1 "decline gate"
expect drop-only-exit1.yml 1 "decline gate"
expect drop-only-closedmerged.yml 1 "decline gate"
expect drop-only-jsonstate.yml 1 "decline gate"

# A workflow yq cannot parse must fail loud, not empty the scan silently.
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# The scenarios below build their workflow at run time: a formatter
# would rewrite the merge keys and anchors of a checked-in fixture.
# Each asserts the exit code and a stderr fragment. The ungated step
# carries an inert marker, never a real merge.
SCENARIO_N=0
# @description Run the script on one built workflow.
# @arg $1 scenario name
# @arg $2 workflow text (printf format, no arguments)
# @arg $3 expected exit code
# @arg $4 expected stderr fragment ('' for none)
# @arg $5 optional directory put first on PATH
function expect_built() {
  local -r name="$1" text="$2" want_exit="$3" want_msg="$4" path_prefix="${5:-}"
  local dir got_exit=0 got_stderr
  SCENARIO_N=$((SCENARIO_N + 1))
  dir="$(mktemp --directory)"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${dir}/wf-${SCENARIO_N}.yml"
  got_stderr="$(PATH="${path_prefix:+${path_prefix}:}${PATH}" WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --force -- "${dir}/wf-${SCENARIO_N}.yml"
  rmdir -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" ]] || [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n  want fragment: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" "${want_msg}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly MERGE_P='p: &P {steps: [{run: "echo PAYLOAD_RAN; gh pr merge --auto 1"}]}\n'
readonly MERGE_Q='q: &Q {steps: [{run: "gh pr merge --auto 1; gh pr view --json state; echo CLOSED|MERGED; exit 1"}]}\n'
expect_built 'a merge list is read first mapping wins: ungated first is a finding' \
  "on: push\n${MERGE_P}${MERGE_Q}jobs: {mlungated: {<<: [*P, *Q]}}\n" 1 'decline gate'
expect_built 'a merge list is read first mapping wins: gated first passes' \
  "on: push\n${MERGE_P}${MERGE_Q}jobs: {mlgated: {<<: [*Q, *P]}}\n" 0 ''
expect_built 'a merge key under jobs: is refused' \
  'x-base: &base {mergekey: {steps: [{run: "echo PAYLOAD_RAN; gh pr merge --auto 1"}]}}\non: push\njobs:\n  <<: *base\n' 1 'which GitHub Actions refuses'
expect_built 'a job id holding a line break is refused' \
  'on: push\njobs:\n  "a\\nb":\n    steps:\n      - run: echo PAYLOAD_RAN; gh pr merge --auto 1\n' 1 'which GitHub Actions refuses'

# A finding for the job keys ends the read of that workflow, so a job
# behind the refused key adds no finding of its own, and a read that
# fails adds no second message: the closing count is one in each.
readonly ONE_FINDING=$'\n1 auto-merge run-block(s) missing the decline gate'
expect_built 'a refused job key hides the jobs behind it' \
  'x-base: &base {mergekey: {steps: [{run: "echo PAYLOAD_RAN"}]}}\non: push\njobs:\n  <<: *base\n  ungated:\n    steps:\n      - run: echo PAYLOAD_RAN; gh pr merge --auto 1\n' 1 \
  "(first: \"<<\")${ONE_FINDING}"
expect_built 'an unparsable workflow is one finding' \
  'jobs: [\n' 1 "could not evaluate workflow with yq (malformed?)${ONE_FINDING}"

# A failing read of the job keys is a finding of its own, even when the
# read of the steps would succeed. The shim fails only the read that
# prints keys as JSON.
yq_stub_dir="$(mktemp --directory)"
real_yq="$(command -v yq)"
cat >"${yq_stub_dir}/yq" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ \${arg} == *'to_json(0)'* ]]; then
    exit 9
  fi
done
exec ${real_yq} "\$@"
EOF
chmod +x -- "${yq_stub_dir}/yq"
expect_built 'a failing job-key read is a finding' \
  'on: push\njobs:\n  clean:\n    steps:\n      - run: echo PAYLOAD_RAN\n' 1 \
  "could not evaluate workflow with yq (malformed?)${ONE_FINDING}" "${yq_stub_dir}"
rm --force -- "${yq_stub_dir}/yq"
rmdir -- "${yq_stub_dir}"

printf 'all tests passed\n'
