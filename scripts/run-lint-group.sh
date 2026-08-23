#!/usr/bin/env bash
# scripts/run-lint-group.sh
#
# @description Run every invariant-lint check in a named group from
# .github/lint-groups.yml inside one devShell, printing a per-check
# pass/fail summary table to stdout and $GITHUB_STEP_SUMMARY. Runs all
# checks even if one fails; exits 1 if any failed, 2 on config error.

set -Eeuo pipefail
IFS=$'\n\t'

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

  local checks
  # A manifest that does not parse is an input this runner could not
  # read. Unchecked, yq's own exit 1 becomes the runner's status and
  # reads as a lint in the group having found a violation.
  if ! checks="$(yq eval ".\"${group}\" // [] | .[]" "${MANIFEST}")"; then
    printf 'cannot read group %s from %s\n' "${group}" "${MANIFEST}" >&2
    exit 2
  fi
  if [[ -z ${checks} ]]; then
    printf 'unknown or empty group: %s\n' "${group}" >&2
    exit 2
  fi

  local failed=0
  local -a rows=()
  local name script test_file start end secs status rc

  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    script="${SCRIPTS_DIR}/check-${name}.sh"
    test_file="${TESTS_DIR}/check-${name}.test.sh"
    rc=0
    start="$(date +%s)"
    if [[ ! -f ${script} ]]; then
      printf '::error::missing check script: %s\n' "${script}" >&2
      rc=1
    else
      if [[ -f ${test_file} ]]; then
        bash "${test_file}" || rc=$?
      fi
      if [[ ${rc} -eq 0 ]]; then
        bash "${script}" || rc=$?
      fi
    fi
    end="$(date +%s)"
    secs=$((end - start))
    if [[ ${rc} -eq 0 ]]; then
      status='pass'
    else
      status='FAIL'
      failed=1
    fi
    rows+=("$(printf '| %s | %s | %ds |' "${name}" "${status}" "${secs}")")
  done <<<"${checks}"

  emit_table
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      printf '### %s\n\n' "${group}"
      emit_table
    } >>"${GITHUB_STEP_SUMMARY}"
  fi

  exit "${failed}"
}

# Emits the markdown summary table from main's `rows` (dynamic scope).
function emit_table() {
  printf '| check | result | time |\n'
  printf '| --- | --- | --- |\n'
  # shellcheck disable=SC2154
  printf '%s\n' "${rows[@]}"
}

main "$@"
