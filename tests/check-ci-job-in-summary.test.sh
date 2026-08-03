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
# A missing manifest is a hard infrastructure error, not drift (exit 1).
expect good 1 "manifest not found" \
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

printf 'all tests passed\n'
