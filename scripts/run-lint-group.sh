#!/usr/bin/env bash
# scripts/run-lint-group.sh
#
# @description Run every invariant-lint check in a named group from
# .github/lint-groups.yml inside one devShell, printing a per-check
# pass/fail summary table to stdout and $GITHUB_STEP_SUMMARY. Checks run
# concurrently, at most CHECK_WORKERS_OVERRIDE (default nproc) at a time,
# with each one's output replayed in manifest order once all have
# finished. Runs all checks even if one fails; exits 1 if any failed, 2
# on config error.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/parallel.sh
source "${_lib_dir}/lib/parallel.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

readonly MANIFEST="${LINT_GROUPS_OVERRIDE:-.github/lint-groups.yml}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

function main() {
  local -r group="${1:-}"
  if [[ -z ${group} ]]; then
    printf 'usage: run-lint-group.sh <group>\n' >&2
    exit 2
  fi
  if ! command -v yq >/dev/null 2>&1; then
    printf 'yq not found on PATH\n' >&2
    exit 2
  fi
  if [[ ! -f ${MANIFEST} ]]; then
    printf 'manifest not found: %s\n' "${MANIFEST}" >&2
    exit 2
  fi

  # The group lookup walks the manifest's entries, which a list would
  # also have, keyed by index, and would report every group as unknown.
  local manifest_shape
  if ! manifest_shape="$(yq eval 'kind' "${MANIFEST}")"; then
    printf 'cannot read group %s from %s\n' "${group}" "${MANIFEST}" >&2
    exit 2
  fi
  if [[ ${manifest_shape} != map ]]; then
    printf '%s: the manifest must be one map of groups (got %s)\n' "${MANIFEST}" "${manifest_shape//$'\n'/,}" >&2
    exit 2
  fi

  local checks
  # A manifest that does not parse is an input this runner could not
  # read. Unchecked, yq's own exit 1 becomes the runner's status and
  # reads as a lint in the group having found a violation. The group name
  # reaches `yq` as data, through `strenv`, and is compared by its base64
  # text: spliced into the expression, a name holding a quote would be
  # read as `yq` code, and `yq` reads `*` and `?` in an index or an `==`
  # comparison as wildcards, which base64 text never holds. Merge keys and
  # aliases are resolved, and of names written twice the last is read, as
  # `yq`'s own lookup reads it.
  if ! checks="$(GROUP="${group}" yq eval 'explode(.) | [to_entries[] | select((.key | tostring | @base64) == (strenv(GROUP) | @base64))] | reverse | .[0] | .value // [] | .[]' "${MANIFEST}")"; then
    printf 'cannot read group %s from %s\n' "${group}" "${MANIFEST}" >&2
    exit 2
  fi
  if [[ -z ${checks} ]]; then
    printf 'unknown or empty group: %s\n' "${group}" >&2
    exit 2
  fi

  local -a names=()
  local name
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    names+=("${name}")
  done <<<"${checks}"

  local results
  results="$(make_temp --directory)"
  # shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
  trap "rm --recursive --force -- '${results}'" EXIT

  local failed=0
  run_parallel run_one "${results}" "${names[@]}" || failed=1

  local -a rows=() name_files=()
  local status secs rc slot
  glob_into name_files 'lint-group results' "${results}/*.name"
  for slot in "${name_files[@]}"; do
    slot="${slot%.name}"
    name="$(<"${slot}.name")"
    rc="$(<"${slot}.rc")"
    secs="$(<"${slot}.secs")"
    cat -- "${slot}.out"
    if [[ ${rc} -eq 0 ]]; then
      status='pass'
    else
      status='FAIL'
    fi
    rows+=("$(printf '| %s | %s | %ds |' "${name}" "${status}" "${secs}")")
  done

  emit_table
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      printf '### %s\n\n' "${group}"
      emit_table
    } >>"${GITHUB_STEP_SUMMARY}"
  fi

  exit "${failed}"
}

# Runs one check by name: its spec test first, then the check script
# only when the test passed; a missing script is a failure. Invoked by
# `run_parallel`, which captures the output and status.
# @arg $1 check name  @arg $2 slot path (unused)
# shellcheck disable=SC2329 # invoked by name through run_parallel
function run_one() {
  local -r script="${SCRIPTS_DIR}/check-$1.sh"
  local -r test_file="${TESTS_DIR}/check-$1.test.sh"
  if [[ ! -f ${script} ]]; then
    printf '::error::missing check script: %s\n' "${script}" >&2
    return 1
  fi
  # Statuses are checked by hand: `run_parallel` invokes this function in
  # a `||` list, where bash suspends errexit for the whole body.
  if [[ -f ${test_file} ]]; then
    bash "${test_file}" || return $?
  fi
  bash "${script}" || return $?
}

# Emits the markdown summary table from main's `rows` (dynamic scope).
function emit_table() {
  printf '| check | result | time |\n'
  printf '| --- | --- | --- |\n'
  # shellcheck disable=SC2154
  printf '%s\n' "${rows[@]}"
}

main "$@"
