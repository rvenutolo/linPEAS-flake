#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-harden-runner-block.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/harden-runner-block"

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

expect good.yml 0 ""
expect good-literal-endpoints.yml 0 ""
expect good-folded-endpoints.yml 0 ""
expect bad-audit.yml 1 "not block"
expect bad-empty.yml 1 "empty allowed-endpoints"
expect bad-missing.yml 1 "empty allowed-endpoints"
expect bad-seq-endpoints.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# --- job keys and merge lists, built at run time ----------------------
# @description Run the script on one workflow written at run time and
# compare the exit code and that stderr contains the message.
# @arg $1 scenario name  @arg $2 workflow text (printf format)
# @arg $3 expected exit code  @arg $4 expected stderr substring
function expect_built() {
  local -r name="$1" text="$2" want_exit="$3" want_msg="$4"
  local dir got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${dir}/built.yml"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" WORKFLOW_FILE_FILTER=built.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${name}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly REFUSED='which GitHub Actions refuses'
readonly HR_AUDIT='x: &p {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: audit}}]}\n'
readonly HR_BLOCK='y: &q {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: block, allowed-endpoints: "a:443"}}]}\n'
expect_built 'merge key under jobs is refused' \
  'x: &base {j: {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: audit}}]}}\non: push\njobs:\n  <<: *base\n' 1 "${REFUSED}"
expect_built 'line-break job key is refused' \
  'on: push\njobs:\n  "a\\nb": {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: block, allowed-endpoints: "a:443"}}]}\n' 1 "${REFUSED}"
expect_built 'empty job key is refused' \
  'on: push\njobs:\n  "": {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: block, allowed-endpoints: "a:443"}}]}\n' 1 "${REFUSED}"
expect_built 'merge list reads the first mapping (audit first) as audit' \
  "${HR_AUDIT}${HR_BLOCK}"'on: push\njobs:\n  a: {<<: [*p, *q]}\n' 1 'is not block'
expect_built 'merge list reads the first mapping (block first) as block' \
  "${HR_AUDIT}${HR_BLOCK}"'on: push\njobs:\n  a: {<<: [*q, *p]}\n' 0 ''

# @description Run the script on one workflow written at run time and
# compare the exit code and the whole of stderr, with the temp directory
# shown as DIR and each of yq's own `Error:` lines shown as `Error: YQ`
# (their wording is yq's). A finding raised twice, a yq failure run twice,
# or a second finding raised from jobs the script should not have read,
# changes the text or the count.
# @arg $1 scenario name  @arg $2 workflow text (printf format)
# @arg $3 expected exit code  @arg $4 expected stderr
function expect_exact() {
  local -r name="$1" text="$2" want_exit="$3" want="$4"
  local dir got_exit=0 raw got
  dir="$(mktemp --directory)"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${dir}/built.yml"
  raw="$(WORKFLOWS_DIR_OVERRIDE="${dir}" WORKFLOW_FILE_FILTER=built.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  # shellcheck disable=SC2001 # the pattern is anchored per line, which a parameter expansion cannot do
  got="$(sed 's/^Error:.*/Error: YQ/' <<<"${raw//"${dir}"/DIR}")"
  if [[ ${got_exit} != "${want_exit}" || ${got} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  got:  %q\n  want: %q\n' "${name}" "${got_exit}" "${want_exit}" "${got}" "${want}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly ODD_HEAD='DIR/built.yml: jobs: holds a job key that is empty, holds a line break or a tab, is not a scalar, or is a merge key, which GitHub Actions refuses; its jobs are not read (first: '
expect_exact 'a workflow yq cannot parse is reported once and counted once' \
  'jobs: [unterminated\n' 1 \
  "Error: YQ
DIR/built.yml: could not evaluate workflow with yq (malformed?)
1 harden-runner step(s) not in block mode with non-empty allowed-endpoints"
expect_exact 'the first refused job key across documents is the one named' \
  'jobs:\n  "a\\nb": {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: audit}}]}\n---\njobs:\n  "": {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: audit}}]}\n' 1 \
  "${ODD_HEAD}"'"a\nb")
1 harden-runner step(s) not in block mode with non-empty allowed-endpoints'
expect_exact 'a refused job key stops the file: its jobs are not read' \
  'jobs:\n  "": {steps: [{uses: step-security/harden-runner@v2, with: {egress-policy: audit}}]}\n' 1 \
  "${ODD_HEAD}"'"")
1 harden-runner step(s) not in block mode with non-empty allowed-endpoints'

printf 'all tests passed\n'
