#!/usr/bin/env bash
# scripts/check-min-permissions.sh
#
# @description Strict least-privilege lint for GitHub Actions
# GITHUB_TOKEN scopes: top-level `permissions: {}` and an explicit
# per-job `permissions:` block in every workflow.

# Strict least-privilege lint for GitHub Actions GITHUB_TOKEN scopes.
# Asserts, for every .github/workflows/*.yml:
#
#   1. Top-level `permissions:` is the empty map `{}`. No scopes
#      granted at workflow scope — every scope must be explicit per-job.
#   2. Every job declares its own `permissions:` block. Inheritance
#      from top-level (which is empty anyway) is not allowed; an
#      omitted block is a lint failure.
#   3. Top-level cannot be `read-all`, `write-all`, or any scalar/
#      list form. (Subsumed by rule 1; a scalar gets a dedicated
#      message, any other shape is reported by its YAML tag.)
#
# See docs/security/min-permissions.md.
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

  # --- top-level permissions ---------------------------------------
  if ! top_tag="$(read_workflow "${f}" '.permissions | tag')"; then
    failed=$((failed + 1))
    continue
  fi
  case "${top_tag}" in
  '!!null')
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: missing top-level `permissions:` (need `permissions: {}`)\n' "${f}" >&2
    failed=$((failed + 1))
    ;;
  '!!str')
    top_val="$(read_workflow "${f}" '.permissions')" || true
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: top-level permissions is scalar %q (need `permissions: {}`)\n' \
      "${f}" "${top_val}" >&2
    failed=$((failed + 1))
    ;;
  '!!map')
    top_len="$(read_workflow "${f}" '.permissions | length')" || true
    if [[ ${top_len} != "0" ]]; then
      top_keys="$(read_workflow "${f}" '.permissions | keys | join(",")')" || true
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: top-level permissions non-empty (keys: %s); need `permissions: {}`\n' \
        "${f}" "${top_keys}" >&2
      failed=$((failed + 1))
    fi
    ;;
  *)
    printf '%s: top-level permissions has unexpected shape (tag=%s)\n' \
      "${f}" "${top_tag}" >&2
    failed=$((failed + 1))
    ;;
  esac

  # --- per-job permissions -----------------------------------------
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (e.g. `jobs:` is not a map) would yield empty input and the per-job
  # scan would pass silently.
  if ! rows="$(yq eval '.jobs | to_entries[] | .key + "\t" + (.value.permissions | tag)' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  [[ -n ${rows} ]] || continue
  while IFS=$'\t' read -r job job_tag; do
    [[ -z ${job} ]] && continue
    case "${job_tag}" in
    '!!null')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q missing `permissions:` block (every job must declare its own)\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
      ;;
    '!!map')
      : # ok; scope-level audit out of scope for this lint
      ;;
    *)
      printf '%s: job %q permissions has unexpected shape (tag=%s)\n' \
        "${f}" "${job}" "${job_tag}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d permissions posture violation(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
