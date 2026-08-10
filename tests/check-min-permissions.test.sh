#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-min-permissions.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/min-permissions"

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
expect bad-no-top.yml 1 "missing top-level"
expect bad-top-nonempty.yml 1 "non-empty"
expect bad-top-write-all.yml 1 "scalar"
expect bad-job-missing.yml 1 "missing"
expect bad-top-list.yml 1 "unexpected shape"
expect bad-job-shape.yml 1 "unexpected shape"

# A jobs map yq cannot traverse (per-job scan) must fail loud, not empty
# the scan silently. permissions: {} stays parseable so this isolates
# the per-job process-substitution site rather than the top-level read.
expect bad-malformed.yml 1 "could not evaluate"

printf 'all tests passed\n'
