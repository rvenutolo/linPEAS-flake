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

# @description Run the guard against one workflow written at run time, so
# that no formatter or workflow linter reads its shape (an alias, a merge
# key, a tag) as a tracked file. The body gets a job that reads a secret
# named after the scenario's file; the finding line is asserted whole.
# @arg $1 scenario name  @arg $2 file name  @arg $3 the workflow's lines above `jobs:`
# @arg $4 expected exit code  @arg $5 secret name
function run_body_scenario() {
  local -r name="$1" file="$2" head="$3" expected_exit="$4" secret="$5"
  local tmpdir stderr_file stdout_file outcome_file
  tmpdir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  # shellcheck disable=SC2016 # the workflow expression is literal text
  printf '%sjobs:\n  a:\n    runs-on: x\n    steps:\n      - run: echo\n        env:\n          T: ${{ secrets.%s }}\n' \
    "${head}" "${secret}" >"${tmpdir}/${file}"
  local lineno
  lineno="$(wc --lines <"${tmpdir}/${file}")"
  local -r expected_stderr="${tmpdir}/${file}:${lineno}: secrets.${secret} not allowed in PR-triggered workflow"

  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${tmpdir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${file}:${lineno}: secrets.${secret} not allowed in PR-triggered workflow" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --line-regexp --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr has no line %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --recursive --force -- "${tmpdir}" "${stderr_file}" \
    "${stdout_file}" "${outcome_file}"
}

# @description Print an `env:` block holding a chain of aliases DEPTH
# deep: A0 is anchored on INNERMOST and each later entry is a map holding
# the one before it under `x`. Sixteen `explode` passes resolve a chain
# fifteen deep and leave an alias in one sixteen deep; a key written as
# an alias at the end of a chain fifteen deep is left too.
# @arg $1 depth  @arg $2 innermost value, as YAML flow text
function alias_chain() {
  local -r depth="$1" innermost="$2"
  local i
  printf 'env:\n  A0: &a0 %s\n' "${innermost}"
  for ((i = 1; i <= depth; i++)); do
    printf '  A%d: &a%d {x: *a%d}\n' "${i}" "${i}" "$((i - 1))"
  done
}

# @description Run the guard against one workflow written at run time
# whose `on:` it must refuse: exit 2, with its own line last.
# @arg $1 scenario name  @arg $2 file name  @arg $3 file body
function run_refused_scenario() {
  local -r name="$1" file="$2" body="$3"
  local tmpdir stderr_file stdout_file outcome_file
  tmpdir="$(mktemp --directory)"
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  printf '%s' "${body}" >"${tmpdir}/${file}"
  local -r want="${tmpdir}/${file}: could not evaluate workflow with yq (malformed?)"
  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${tmpdir}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${file}: could not evaluate workflow with yq (malformed?)" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ $(tail --lines=1 -- "${stderr_file}") != "${want}" ]]; then
    printf 'FAIL: %s — last stderr line is not %q\n' "${name}" "${want}" >&2
    cat -- "${stderr_file}" >&2
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
    'bad-malformed.yml' 2 'bad-malformed.yml: could not evaluate' ''
  # A PR trigger written through an anchor puts the workflow in scope,
  # whichever part of `on:` the alias stands for.
  run_body_scenario 'aliased list item pull_request with secret fails' \
    'alias-item.yml' $'name: &t pull_request\non: [push, *t]\n' 1 'ALIAS_ITEM'
  run_body_scenario 'aliased map key pull_request with secret fails' \
    'alias-key.yml' $'name: &t pull_request\non:\n  *t : {}\n' 1 'ALIAS_KEY'
  run_body_scenario 'aliased string on: pull_request_target with secret fails' \
    'alias-string.yml' $'name: &t pull_request_target\non: *t\n' 1 'ALIAS_STRING'
  run_body_scenario 'aliased list on: with secret fails' \
    'alias-list.yml' $'env:\n  X: &t [pull_request]\non: *t\n' 1 'ALIAS_LIST'
  run_body_scenario 'aliased map on: with secret fails' \
    'alias-map.yml' $'env:\n  X: &t\n    pull_request: {}\non: *t\n' 1 'ALIAS_MAP'
  # An alias inside what another alias stands for, and an `on` key
  # itself written as an alias.
  run_body_scenario 'nested aliased list item pull_request with secret fails' \
    'nested-item.yml' $'name: &k pull_request\nenv:\n  A: &m [push, *k]\non: *m\n' 1 'NESTED_ITEM'
  run_body_scenario 'nested aliased map key pull_request with secret fails' \
    'nested-key.yml' $'name: &k pull_request\nenv:\n  A: &m {*k : {}}\non: *m\n' 1 'NESTED_KEY'
  run_body_scenario 'aliased on key with pull_request and secret fails' \
    'alias-on-key.yml' $'name: &k on\n*k : [pull_request]\n' 1 'ALIAS_ON_KEY'
  # The depth boundary: a chain fifteen deep is read, one sixteen deep is
  # refused, and so is one fifteen deep ending in a key written as an
  # alias, the one alias the passes leave there.
  run_body_scenario 'pull_request beside a chain fifteen deep with secret fails' \
    'chain-15.yml' "$(alias_chain 15 '[a]')"$'\non:\n  pull_request:\n    x: *a15\n' 1 'CHAIN_FIFTEEN'
  run_refused_scenario 'on: holding a chain sixteen deep is refused' \
    'chain-16.yml' "$(alias_chain 16 '[a]')"$'\non:\n  pull_request:\n    x: *a16\n'
  run_refused_scenario 'on: holding a chain fifteen deep ending in a key is refused' \
    'chain-15-key.yml' $'name: &k push\n'"$(alias_chain 15 '{*k : {}}')"$'\non:\n  pull_request:\n    x: *a15\n'
  # A root with more than one key that resolves to `on` has no one `on:`.
  run_refused_scenario 'on: given twice is refused' \
    'on-twice.yml' $'name: &k on\non: [push]\n*k : [pull_request]\n'
  # GitHub Actions refuses a merge key, so this workflow cannot run; the
  # guard still scans a workflow whose merge brings in a PR trigger.
  run_body_scenario 'merge-key pull_request with secret fails' \
    'merge-key.yml' $'env:\n  X: &t\n    pull_request: {}\non:\n  <<: *t\n' 1 'MERGE_KEY'
  # A list or a map is read whatever tag it carries.
  run_body_scenario 'tagged map pull_request with secret fails' \
    'tagged-map.yml' $'on: !x\n  pull_request: {}\n' 1 'TAGGED_MAP'
  run_body_scenario 'tagged list pull_request with secret fails' \
    'tagged-list.yml' $'on: !x [pull_request]\n' 1 'TAGGED_LIST'
  run_body_scenario 'tagged string pull_request with secret fails' \
    'tagged-string.yml' $'on: !x pull_request\n' 1 'TAGGED_STRING'
  # Only `on:` is resolved: an alias `yq` cannot resolve elsewhere in the
  # file (a merge of a string) does not stop a readable `on:` being read.
  run_body_scenario 'pull_request beside an unresolvable merge elsewhere fails' \
    'merge-elsewhere.yml' $'name: &s str\non: pull_request\nenv:\n  <<: *s\n' 1 'MERGE_ELSEWHERE'
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
