#!/usr/bin/env bash
# tests/check-protect-main.test.sh
#
# Failure-mode harness for scripts/check-protect-main.sh.
# Mirrors tests/check-tag-protection.test.sh.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-protect-main.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-protect-main"

failures=0

# @arg $1 scenario name
# @arg $2 fixture subdir
# @arg $3 expected exit
# @arg $4 expected stderr substring (empty skips)
function run_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local stderr_file
  stderr_file="$(mktemp)"

  local actual_exit=0
  RULESET_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/live.json" \
    MIRROR_JSON_OVERRIDE="${FIXTURES}/${fixture_dir}/mirror.json" \
    DOC_TABLE_OVERRIDE="${FIXTURES}/${fixture_dir}/required-checks.md" \
    "${SCRIPT}" >/dev/null 2>"${stderr_file}" || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${stderr_file}"
}

function main() {
  run_scenario 'matching live + mirror passes' \
    'good' 0 ''
  run_scenario 'wrong ruleset name fails' \
    'bad-name' 1 'name drift'
  run_scenario 'non-merge allowed methods fails' \
    'bad-wrong-merge' 1 'allowed_merge_methods drift'
  run_scenario 'required-checks drift fails' \
    'bad-required-checks-drift' 1 'required-status-checks drift'
  run_scenario 'integration_id drift fails' \
    'bad-integration-id-drift' 1 'integration_id drift'
  run_scenario 'doc-table drift fails' \
    'bad-doc-table-drift' 1 'doc-table drift'
  run_scenario 'non-empty bypass_actors fails' \
    'bad-bypass-actors' 1 'bypass_actors non-empty'
  run_scenario 'missing required_signatures rule fails' \
    'bad-missing-rule' 1 'missing rule: required_signatures'
  run_scenario 'strict policy false fails' \
    'bad-strict-false' 1 'strict_required_status_checks_policy drift'
  run_scenario 'thread-resolution false fails' \
    'bad-thread-resolution-false' 1 'required_review_thread_resolution drift'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
