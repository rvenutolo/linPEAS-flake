#!/usr/bin/env bash
# tests/check-pr-workflows-no-secrets.test.sh
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/pr-workflows-no-secrets"
readonly SCRIPT="${REPO_ROOT}/scripts/check-pr-workflows-no-secrets.sh"

failures=0

# @description Run the guard against a single fixture in isolation;
# assert exit code and (for failures) a stderr substring.
# @arg $1 scenario name
# @arg $2 fixture filename under FIXTURES
# @arg $3 expected exit code (0 or 1)
# @arg $4 expected stderr substring (empty string skips the check)
# @arg $5 expected stdout substring (empty string skips the check)
function run_scenario() {
  local -r name="$1"
  local -r fixture="$2"
  local -r expected_exit="$3"
  local -r expected_stderr="$4"
  local -r expected_stdout="$5"

  local tmpdir
  tmpdir="$(mktemp --directory)"
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  mkdir --parents "${tmpdir}/wfs"
  cp -- "${FIXTURES}/${fixture}" "${tmpdir}/wfs/${fixture}"

  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${tmpdir}/wfs" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi

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
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --recursive --force -- "${tmpdir}" "${stderr_file}" \
    "${stdout_file}" "${outcome_file}"
}

function main() {
  # A pass states how much of the directory was actually read. A workflow
  # that was scanned and held no disallowed secret and a workflow that
  # was never scanned because no PR trigger put it in scope are the same
  # verdict, and only the scanned-versus-skipped split says which one an
  # operator is looking at.
  run_scenario 'clean pull_request workflow passes' \
    'clean-pr-workflow.yml' 0 '' \
    'examined 1 workflow(s): 1 scanned as PR-triggered, 0 skipped as not PR-triggered; 1 secrets.GITHUB_TOKEN reference(s) allowed'
  run_scenario 'pull_request with non-GITHUB_TOKEN secret fails' \
    'secrets-leak-pr-workflow.yml' 1 'secrets.DOCKERHUB_TOKEN not allowed' ''
  run_scenario 'pull_request_target with secret fails' \
    'pr-target-workflow.yml' 1 'secrets.BUMP_PAT not allowed' ''
  run_scenario 'push-only workflow with secret passes' \
    'non-pr-workflow.yml' 0 '' \
    'examined 1 workflow(s): 0 scanned as PR-triggered, 1 skipped as not PR-triggered; 0 secrets.GITHUB_TOKEN reference(s) allowed'
  run_scenario 'mixed pull_request + push with non-allowed secret fails' \
    'mixed-on-block.yml' 1 'secrets.DOCKERHUB_TOKEN not allowed' ''
  run_scenario 'flow-string pull_request with secret fails' \
    'flow-string-pr.yml' 1 'secrets.DOCKERHUB_TOKEN not allowed' ''
  run_scenario 'flow-seq including pull_request with secret fails' \
    'flow-seq-pr.yml' 1 'secrets.DOCKERHUB_TOKEN not allowed' ''
  # .yaml workflow extension: fixed once the discovery glob covers *.yaml too.
  run_scenario 'pull_request .yaml workflow with non-GITHUB_TOKEN secret fails' \
    'bad-secret.yaml' 1 'secrets.SUPER_SECRET not allowed' ''
  # flow-map `on: { pull_request: {} }`: fixed once detection goes via yq.
  run_scenario 'flow-map pull_request with non-GITHUB_TOKEN secret fails' \
    'bad-flowmap.yml' 1 'secrets.SUPER_SECRET not allowed' ''
  # Malformed YAML: a workflow yq cannot parse is a loud tooling error,
  # not a silent skip.
  run_scenario 'malformed workflow is a tooling error' \
    'bad-malformed.yml' 2 'could not evaluate' ''
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
