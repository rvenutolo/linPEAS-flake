#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-uses-sha-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/uses-sha-pinned"

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

# A single-violation top-level file must report exactly one violation line;
# the file-list glob must not match (and re-scan) a top-level *.yml twice.
count="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" WORKFLOW_FILE_FILTER=bad-tag.yml \
  "${SCRIPT}" 2>&1 >/dev/null | grep -c 'not SHA-pinned')" || true
if [[ ${count} != 1 ]]; then
  printf 'FAIL bad-tag.yml: expected exactly 1 violation line, got %s\n' "${count}" >&2
  exit 1
fi
printf 'OK   bad-tag.yml violation counted once\n'

printf 'all tests passed\n'
