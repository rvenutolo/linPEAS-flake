#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-harden-runner-first.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/harden-runner-first"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"

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
expect bad-missing.yml 1 "first step is"
expect bad-not-first.yml 1 "first step is"
expect bad-unpinned.yml 1 "not SHA-pinned"
expect bad-run-first.yml 1 "no first-step"
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# Under en_US.UTF-8 a bash `[0-9a-f]` range also matches non-ASCII
# characters, so a harden-runner ref of 39 hex digits and one such
# character would read as SHA-pinned. The workflow is built at run time
# and the whole of stderr is compared.
require_locale_gap en_US.UTF-8 || exit 1
# @arg $1 scenario name  @arg $2 the whole ref of the first step's uses:
function expect_hr_ref_refused() {
  local -r name="$1" ref="$2"
  local hr_dir hr_exit=0 hr_err hr_want
  hr_dir="$(mktemp --directory)"
  printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: %s\n      - run: "true"\n' "${ref}" >"${hr_dir}/hr.yml"
  hr_err="$(LC_ALL=en_US.UTF-8 WORKFLOWS_DIR_OVERRIDE="${hr_dir}" WORKFLOW_FILE_FILTER=hr.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || hr_exit=$?
  hr_want="${hr_dir}/hr.yml: job a harden-runner ref ${ref} not SHA-pinned
1 job(s) missing harden-runner as first step"
  rm --recursive --force -- "${hr_dir}"
  if [[ ${hr_exit} != 1 || ${hr_err} != "${hr_want}" ]]; then
    printf 'FAIL %s: exit %s (want 1)\n  stderr: %s\n  want:   %s\n' \
      "${name}" "${hr_exit}" "${hr_err}" "${hr_want}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
hr_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_hr_ref_refused 'non-ASCII harden-runner sha rejected under en_US.UTF-8' \
  "step-security/harden-runner@${hr_sha:0:39}é"
expect_hr_ref_refused 'text after the harden-runner sha rejected under en_US.UTF-8' \
  "step-security/harden-runner@${hr_sha}é"

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
    exit 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${name}" "${want_msg}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly REFUSED='which GitHub Actions refuses'
readonly HR_STEP="{uses: step-security/harden-runner@${hr_sha}}"
readonly MERGE_P='x: &p {steps: [{run: echo PAYLOAD_RAN}]}\n'
readonly MERGE_Q="y: &q {steps: [${HR_STEP}]}\\n"
expect_built 'merge key under jobs is refused' \
  'x: &base {j: {steps: [{run: echo PAYLOAD_RAN}]}}\npermissions: {}\njobs:\n  <<: *base\n' 1 "${REFUSED}"
expect_built 'line-break job key is refused' \
  "permissions: {}\\njobs:\\n  \"a\\\\nb\": {steps: [${HR_STEP}]}\\n" 1 "${REFUSED}"
expect_built 'empty job key is refused' \
  "permissions: {}\\njobs:\\n  \"\": {steps: [${HR_STEP}]}\\n" 1 "${REFUSED}"
expect_built 'merge list reads the first mapping (run first) as a run step' \
  "${MERGE_P}${MERGE_Q}"'permissions: {}\njobs:\n  a: {runs-on: x, <<: [*p, *q]}\n' 1 'no first-step'
expect_built 'merge list reads the first mapping (harden-runner first) as harden-runner' \
  "${MERGE_P}${MERGE_Q}"'permissions: {}\njobs:\n  a: {runs-on: x, <<: [*q, *p]}\n' 0 ''

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
1 job(s) missing harden-runner as first step"
expect_exact 'the first refused job key across documents is the one named' \
  'jobs:\n  "a\\nb": {steps: [{run: echo PAYLOAD_RAN}]}\n---\njobs:\n  "": {steps: [{run: echo PAYLOAD_RAN}]}\n' 1 \
  "${ODD_HEAD}"'"a\nb")
1 job(s) missing harden-runner as first step'
expect_exact 'a refused job key stops the file: its jobs are not read' \
  'jobs:\n  "": {steps: [{run: echo PAYLOAD_RAN}]}\n' 1 \
  "${ODD_HEAD}"'"")
1 job(s) missing harden-runner as first step'

printf 'all tests passed\n'
