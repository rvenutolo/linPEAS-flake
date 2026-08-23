#!/usr/bin/env bash
# scripts/check-workflow-concurrency.sh
#
# @description Lint: every workflow under .github/workflows/*.yml
# declares a top-level `concurrency:` block with a non-empty
# `group:` string.

# Lint: every workflow under .github/workflows/*.yml declares a
# top-level `concurrency:` block with a non-empty `group:`. Without
# one, cron pile-ups and PR/push overlap can multiply runner cost
# and let an in-flight run race a fresh push on the same ref.
#
# A workflow satisfies the lint when:
#   - `.concurrency` is a map
#   - `.concurrency.group` is a non-empty string
#
# `cancel-in-progress` is not required by this lint; the group alone
# is the load-bearing setting. Some pipelines (release-on-bump) keep
# `cancel-in-progress: false` deliberately to serialize.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift. Exits 2 when the check
# cannot run: `yq` is absent from PATH, the workflow globs match no
# file, or WORKFLOW_FILE_FILTER selects none of the files they matched.
# An empty scan set is a could-not-run rather than a clean tree;
# LINT_ALLOW_EMPTY_SCAN=1 accepts one deliberately.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# @description Print one expression's value from a workflow. Returns
# non-zero, having named the file, when `yq` cannot evaluate it. `yq` is
# on PATH — an absent one is reported by the guard above — so a failure
# here is a workflow in the scanned tree that does not parse, which is a
# fact about this repo and is reported the way the scan reports any
# other: a finding against that file, with the scan continuing. What
# must not happen is the unchecked case, where yq's own status ends the
# run mid-tree and every workflow after this one goes unscanned.
# @arg $1 workflow path
# @arg $2 yq expression
# @exitcode 1 yq could not evaluate the expression against the file
function read_workflow() {
  local -r file="$1" expr="$2"
  local value
  if ! value="$(yq eval "${expr}" "${file}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${file}" >&2
    return 1
  fi
  printf '%s' "${value}"
}

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  if ! conc_tag="$(read_workflow "${f}" '.concurrency | tag')"; then
    failed=$((failed + 1))
    continue
  fi
  case "${conc_tag}" in
  '!!null')
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: missing top-level `concurrency:` (need `group:` to bound parallel runs on a ref)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
    ;;
  '!!map') ;;
  *)
    printf '%s: top-level concurrency has unexpected shape (tag=%s); expected map\n' \
      "${f}" "${conc_tag}" >&2
    failed=$((failed + 1))
    continue
    ;;
  esac

  group_tag="$(read_workflow "${f}" '.concurrency.group | tag')" || true
  case "${group_tag}" in
  '!!null')
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: top-level concurrency is missing `group:`\n' "${f}" >&2
    failed=$((failed + 1))
    ;;
  '!!str')
    group_val="$(read_workflow "${f}" '.concurrency.group')" || true
    if [[ -z ${group_val} ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: top-level concurrency `group:` is empty\n' "${f}" >&2
      failed=$((failed + 1))
    fi
    ;;
  *)
    printf '%s: top-level concurrency.group has unexpected shape (tag=%s); expected string\n' \
      "${f}" "${group_tag}" >&2
    failed=$((failed + 1))
    ;;
  esac
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d workflow(s) missing or invalid top-level concurrency\n' "${failed}" >&2
  exit 1
fi
exit 0
