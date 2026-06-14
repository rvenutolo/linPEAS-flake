#!/usr/bin/env bash
# scripts/run-lint-group.sh
#
# @description Run every invariant-lint check in a named group from
# .github/lint-groups.yml inside one devShell, with bounded parallelism,
# printing a per-check pass/fail summary table to stdout and
# $GITHUB_STEP_SUMMARY. Runs all checks even if one fails; exits 1 if any
# failed, 2 on config error.

set -Eeuo pipefail
IFS=$'\n\t'

readonly MANIFEST="${LINT_GROUPS_OVERRIDE:-.github/lint-groups.yml}"
readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

# shellcheck source=scripts/lib/run-parallel.sh
# The pre-commit shellcheck hook runs without -x, so SC1091 ("not
# following sourced file") fires on this dynamic path; the helper is
# linted on its own. Suppress the info to keep the gate green.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/lib/run-parallel.sh"

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
  checks="$(yq eval ".\"${group}\" // [] | .[]" "${MANIFEST}")"
  if [[ -z ${checks} ]]; then
    printf 'unknown or empty group: %s\n' "${group}" >&2
    exit 2
  fi

  # Build one job per check. Each job runs the checker's unit test (if
  # present) first, then the checker; a missing script is a failure. The
  # command runs inside `bash -c` in a worker subshell, so it must be
  # self-contained. SCRIPTS_DIR/TESTS_DIR are expanded here, at build time.
  local -a jobs=()
  local name script test_file cmd
  while IFS= read -r name; do
    [[ -n ${name} ]] || continue
    script="${SCRIPTS_DIR}/check-${name}.sh"
    test_file="${TESTS_DIR}/check-${name}.test.sh"
    if [[ ! -f ${script} ]]; then
      cmd="printf '::error::missing check script: %s\n' '${script}' >&2; exit 1"
    elif [[ -f ${test_file} ]]; then
      cmd="bash '${test_file}' && bash '${script}'"
    else
      cmd="bash '${script}'"
    fi
    jobs+=("${name}|${cmd}")
  done <<<"${checks}"

  local rc=0
  run_parallel jobs check "${group}" || rc=$?
  exit "${rc}"
}

main "$@"
