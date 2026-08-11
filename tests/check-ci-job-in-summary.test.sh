#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-ci-job-in-summary.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ci-job-in-summary"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  # Optional 4th/5th args override the lint-groups manifest + scripts dir
  # so the manifest-coverage assertion can be exercised against a fixture.
  # Optional 6th arg overrides the EXEMPT list. Only set when provided so
  # the script's own defaults apply otherwise.
  local -a env_overrides=(
    "WORKFLOWS_DIR_OVERRIDE=${FIXTURES}/${fixture}"
    "CI_WORKFLOW_OVERRIDE=${FIXTURES}/${fixture}/ci.yml"
    "CATEGORIES_FILE_OVERRIDE=${FIXTURES}/${fixture}/categories.yml"
  )
  [[ -n ${4:-} ]] && env_overrides+=("LINT_GROUPS_OVERRIDE=${4}")
  [[ -n ${5:-} ]] && env_overrides+=("SCRIPTS_DIR_OVERRIDE=${5}")
  [[ -n ${6:-} ]] && env_overrides+=("EXEMPT_OVERRIDE=${6}")
  local got_exit=0 got_stderr
  got_stderr="$(env "${env_overrides[@]}" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
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

expect good 0 ""
expect bad-missing-category 1 "EXEMPT"
expect bad-orphan-category 1 "does not match any job"
# Manifest coverage: a lint-groups basename with no real check script fails.
expect bad-missing-manifest-check 1 "lint-groups basename" \
  "${FIXTURES}/bad-missing-manifest-check/lint-groups.yml" \
  "${FIXTURES}/bad-missing-manifest-check/scripts"
# A missing manifest is a hard infrastructure error, not drift: nothing was
# cross-checked, so it carries the could-not-run code (exit 2).
expect good 2 "manifest not found" \
  "${FIXTURES}/bad-missing-manifest-check/does-not-exist.yml" \
  "${FIXTURES}/bad-missing-manifest-check/scripts"
# An unmapped auxiliary job with no EXEMPT entry fails — the exemption in
# the next scenario is load-bearing, not incidentally passing.
expect good-exempt 1 "EXEMPT"
# An EXEMPT entry naming a real, unmapped ci.yml job exempts it.
expect good-exempt 0 "" "" "" "aux"
# An EXEMPT entry that is not a ci.yml job exempts nothing.
expect good 1 "is not a job" "" "" "not-a-real-job"
# An EXEMPT entry that is already a category key exempts nothing — the
# forward loop matches the category map first and never reaches it.
expect good 1 "already a key" "" "" "foo"
# A lint-groups manifest yq cannot parse is a tooling error, not drift
# — it must fail loud (exit 2) rather than silently skip coverage.
expect good 2 "" "${FIXTURES}/bad-malformed-manifest/lint-groups.yml" ""

# The two files the cross-check reads are inputs, not findings: absent, the
# lint has compared nothing and must not report drift.
expect does-not-exist 2 "ci workflow not found"

missing_categories_exit=0
missing_categories_stderr="$(env \
  "WORKFLOWS_DIR_OVERRIDE=${FIXTURES}/good" \
  "CI_WORKFLOW_OVERRIDE=${FIXTURES}/good/ci.yml" \
  "CATEGORIES_FILE_OVERRIDE=${FIXTURES}/good/does-not-exist.yml" \
  "${SCRIPT}" 2>&1 >/dev/null)" || missing_categories_exit=$?
if [[ ${missing_categories_exit} != 2 ]]; then
  printf 'FAIL missing-categories: exit %s, want 2\n  stderr: %s\n' \
    "${missing_categories_exit}" "${missing_categories_stderr}" >&2
  exit 1
fi
if [[ ${missing_categories_stderr} != *"categories file not found"* ]]; then
  printf 'FAIL missing-categories: stderr missing %q\n  got: %s\n' \
    "categories file not found" "${missing_categories_stderr}" >&2
  exit 1
fi
printf 'OK   missing-categories\n'

# --print-exempt is the shared source of the ci-job exemption list for
# scripts/refresh-enforcement-matrix.sh. It must exit 0 and emit exactly
# the list — nothing at all when the list is empty, so that an empty
# stdout means "no exemptions" and a nonzero exit means "unreadable".
function expect_print_exempt() {
  local -r label="$1" override="$2" want="$3"
  local got exit_code=0
  if [[ -n ${override} ]]; then
    got="$(EXEMPT_OVERRIDE="${override}" "${SCRIPT}" --print-exempt)" || exit_code=$?
  else
    got="$("${SCRIPT}" --print-exempt)" || exit_code=$?
  fi
  if [[ ${exit_code} != 0 ]]; then
    printf 'FAIL %s: exit %s, want 0\n' "${label}" "${exit_code}" >&2
    return 1
  fi
  if [[ ${got} != "${want}" ]]; then
    printf 'FAIL %s: got %q, want %q\n' "${label}" "${got}" "${want}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${label}"
}

expect_print_exempt 'print-exempt: empty list prints nothing' "" ""
expect_print_exempt 'print-exempt: single entry' "aux-sandbox" "aux-sandbox"
expect_print_exempt 'print-exempt: multiple entries, one per line' \
  $'aux-one\naux-two' $'aux-one\naux-two'

# An unrecognized argument exits 2 so a caller that asks for a mode this
# script does not have fails loud instead of reading an empty list.
unknown_arg_exit=0
"${SCRIPT}" --not-a-mode >/dev/null 2>&1 || unknown_arg_exit=$?
if [[ ${unknown_arg_exit} != 2 ]]; then
  printf 'FAIL unknown-argument: exit %s, want 2\n' "${unknown_arg_exit}" >&2
  exit 1
fi
printf 'OK   unknown-argument\n'

printf 'all tests passed\n'
