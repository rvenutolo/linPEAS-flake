#!/usr/bin/env bash
# tests/check-pr-workflows-no-secrets.test.sh
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/pr-workflows-no-secrets"
readonly SCRIPT="${REPO_ROOT}/scripts/check-pr-workflows-no-secrets.sh"

failures=0

# @description Run the guard against a single fixture in isolation;
# assert exit code and (for failures) a stderr substring.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 or 1)
# @arg $4 expected stderr substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"

  local tmpdir
  tmpdir="$(mktemp --directory)"
  local stderr_file
  stderr_file="$(mktemp)"

  mkdir --parents "${tmpdir}/wfs"
  cp -- "${FIXTURES}/${fixture}" "${tmpdir}/wfs/${fixture}"

  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${tmpdir}/wfs" \
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

  rm --recursive --force -- "${tmpdir}" "${stderr_file}"
}

function main() {
  run_scenario 'clean pull_request workflow passes' \
    'clean-pr-workflow.yml' 0 ''
  run_scenario 'pull_request with non-GITHUB_TOKEN secret fails' \
    'secrets-leak-pr-workflow.yml' 1 'secrets.DOCKERHUB_TOKEN not allowed'
  run_scenario 'pull_request_target with secret fails' \
    'pr-target-workflow.yml' 1 'secrets.BUMP_PAT not allowed'
  run_scenario 'push-only workflow with secret passes' \
    'non-pr-workflow.yml' 0 ''
  run_scenario 'mixed pull_request + push with non-allowed secret fails' \
    'mixed-on-block.yml' 1 'secrets.DOCKERHUB_TOKEN not allowed'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
