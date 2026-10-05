#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-uses-sha-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/uses-sha-pinned"
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
expect good-quoted.yml 0 ""
expect bad-tag.yml 1 "not SHA-pinned"
expect bad-branch.yml 1 "not SHA-pinned"
expect bad-short-sha.yml 1 "not SHA-pinned"

# .yaml workflow extension: fixed once the discovery glob covers *.yaml too.
expect bad-tag-pinned.yaml 1 "not SHA-pinned"

# action.yaml composite: fixed alongside the .yaml workflow glob above.
expect action.yaml 1 "not SHA-pinned"

expect no-such-workflow.yml 2 'selected 0 of'

# Flow-style unpinned ref, generated at runtime: a committed flow-mapping
# fixture is unusable because prettier normalizes `{uses: x}` to
# `{ uses: x }` while yamllint forbids the inner-brace spaces. The old
# line-grep selector never matched a flow-style step, so the unpinned ref
# bypassed the lint entirely.
flowdir="$(mktemp --directory)"
printf 'on: push\njobs:\n  a:\n    steps:\n      - {uses: actions/checkout@v4}\n' \
  >"${flowdir}/flow.yml"
flow_exit=0
flow_err="$(WORKFLOWS_DIR_OVERRIDE="${flowdir}" WORKFLOW_FILE_FILTER=flow.yml \
  "${SCRIPT}" 2>&1 >/dev/null)" || flow_exit=$?
rm --recursive --force -- "${flowdir}"
if [[ ${flow_exit} != 1 || ${flow_err} != *"not SHA-pinned"* ]]; then
  printf 'FAIL flow-style: exit %s (want 1)\n  stderr: %s\n' "${flow_exit}" "${flow_err}" >&2
  exit 1
fi
printf 'OK   flow-style unpinned rejected\n'

# Without yq nothing is scanned, so the lint has found no unpinned ref and
# must not report drift. Run through an absolute bash with an empty PATH:
# the script is reached, its own tool guard is what fires.
bash_abs="$(command -v bash)"
noyq_exit=0
noyq_err="$(env --unset=BASH_ENV PATH=/nonexistent \
  "${bash_abs}" "${SCRIPT}" 2>&1 >/dev/null)" || noyq_exit=$?
if [[ ${noyq_exit} != 2 || ${noyq_err} != *"yq not found on PATH"* ]]; then
  printf 'FAIL yq-absent: exit %s (want 2)\n  stderr: %s\n' "${noyq_exit}" "${noyq_err}" >&2
  exit 1
fi
printf 'OK   yq absent exits tooling code\n'

# A single-violation top-level file must report exactly one violation line;
# the file-list glob must not match (and re-scan) a top-level *.yml twice.
count="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" WORKFLOW_FILE_FILTER=bad-tag.yml \
  "${SCRIPT}" 2>&1 >/dev/null | grep -c 'not SHA-pinned')" || true
if [[ ${count} != 1 ]]; then
  printf 'FAIL bad-tag.yml: expected exactly 1 violation line, got %s\n' "${count}" >&2
  exit 1
fi
printf 'OK   bad-tag.yml violation counted once\n'

# @description Scan one workflow written to a temp dir at run time and
# compare the whole of stderr, so the shapes built here (tags) are not
# tracked files a formatter or workflow linter reads.
# @arg $1 file name, which is also the scenario's label
# @arg $2 file body  @arg $3 expected exit status
# @arg $4 expected stderr, with DIR standing for the temp dir
function expect_body() {
  local -r name="$1" body="$2" want_exit="$3"
  local dir got_exit=0 got_stderr want
  dir="$(mktemp --directory)"
  printf '%s' "${body}" >"${dir}/${name}"
  want="${4//DIR/${dir}}"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want %s, and stderr %q\n  got: %s\n' \
      "${name}" "${got_exit}" "${want_exit}" "${want}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

# A step is read by kind: a step map carrying a tag of its own is still
# a step, and its reference is checked.
expect_body step-xtag.yml $'on: push\njobs:\n  a:\n    steps:\n      - !x {uses: actions/checkout@v4}\n' 1 \
  $'DIR/step-xtag.yml: actions/checkout@v4 not SHA-pinned (need owner/repo@<40-hex>)\n1 unpinned uses: reference(s) found'
expect_body step-strtag.yml $'on: push\njobs:\n  a:\n    steps:\n      - !!str {uses: actions/setup-node@v4}\n' 1 \
  $'DIR/step-strtag.yml: actions/setup-node@v4 not SHA-pinned (need owner/repo@<40-hex>)\n1 unpinned uses: reference(s) found'

# Under en_US.UTF-8 a bash `[0-9a-f]` range also matches non-ASCII
# characters, so a ref of 39 hex digits and one such character would read
# as a SHA. GitHub resolves it as a tag or branch name, which can move.
require_locale_gap en_US.UTF-8 || exit 1
LC_ALL=en_US.UTF-8 expect_body sha-non-ascii.yml $'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaé\n      - uses: actions/setup-node@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa５\n' 1 \
  $'DIR/sha-non-ascii.yml: actions/checkout@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaé not SHA-pinned (need owner/repo@<40-hex>)\nDIR/sha-non-ascii.yml: actions/setup-node@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa５ not SHA-pinned (need owner/repo@<40-hex>)\n2 unpinned uses: reference(s) found'

printf 'all tests passed\n'
