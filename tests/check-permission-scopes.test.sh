#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-permission-scopes.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/permission-scopes"

# Forward-pass cases run filtered to a single fixture in the shared dir.
function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    SCOPE_ALLOWLIST_OVERRIDE="${FIXTURES}/allowlist.yml" \
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

# Stale detection lives in the script's reverse pass, which is skipped under
# WORKFLOW_FILE_FILTER (so a single-fixture forward run does not false-positive
# on the shared allowlist's other entries). To genuinely exercise stale
# detection, the stale case runs UNFILTERED against its own isolated subdir
# (tests/fixtures/permission-scopes/stale/) holding just the stale workflow
# plus a matching allowlist, so the reverse pass runs and flags the entry.
function expect_unfiltered() {
  local -r dir="$1" allowlist="$2" want_exit="$3" want_msg="$4" label="$5"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" \
    SCOPE_ALLOWLIST_OVERRIDE="${allowlist}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${label}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

expect good.yml 0 ""
expect good-read-only.yml 0 ""
expect bad-over-grant.yml 1 "contents"
expect bad-job-not-in-allowlist.yml 1 "writer"
expect_unfiltered "${FIXTURES}/stale" "${FIXTURES}/stale/allowlist.yml" 1 "stale" bad-stale-allowlist.yml

# Real-tree guard: the committed allowlist must match the live workflows.
real_exit=0
"${SCRIPT}" >/dev/null 2>&1 || real_exit=$?
if [[ ${real_exit} != 0 ]]; then
  printf 'FAIL real-tree: .github/workflows vs .github/permission-scopes.yml exit %s, want 0\n' "${real_exit}" >&2
  exit 1
fi
printf 'OK   real-tree\n'

printf 'all tests passed\n'
