#!/usr/bin/env bash
# scripts/check-pull-request-target-absent.sh
#
# @description Lint: hard-fail if any workflow under
# .github/workflows/*.yml uses the `pull_request_target` trigger,
# foreclosing the canonical Actions privilege-escalation footgun.

# Lint: hard-fail if any workflow under .github/workflows/*.yml uses
# the `pull_request_target` trigger.
#
# `pull_request_target` runs the **base** ref's workflow definition
# with the **head** ref's code checked out (when the workflow opts
# into checking out the PR head) AND the full secret scope of the
# base repo. It's the canonical Actions privilege-escalation footgun:
# a fork PR can introduce malicious code that the base-ref workflow
# then executes with secret access.
#
# This repo never uses it. The lint forecloses regression — adding
# the trigger requires also deleting this script.
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

  # `on:` may be a string ("push"), a sequence ([push, pull_request]),
  # or a map ({push: ..., pull_request_target: ...}). Check all three.
  if ! on_tag="$(read_workflow "${f}" '.on | tag')"; then
    failed=$((failed + 1))
    continue
  fi
  case "${on_tag}" in
  '!!null')
    continue
    ;;
  '!!str')
    if [[ "$(yq eval '.on' "${f}")" == "pull_request_target" ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: uses `pull_request_target` trigger (forbidden — base-ref workflow with head-ref code + full secrets)\n' \
        "${f}" >&2
      failed=$((failed + 1))
    fi
    ;;
  '!!seq')
    if yq eval '.on[] | select(. == "pull_request_target")' "${f}" | grep --quiet pull_request_target; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: uses `pull_request_target` trigger (forbidden — base-ref workflow with head-ref code + full secrets)\n' \
        "${f}" >&2
      failed=$((failed + 1))
    fi
    ;;
  '!!map')
    # A present-but-null key (bare `pull_request_target:` with no
    # sub-keys) is still the forbidden trigger — GitHub fires on all its
    # activity types. `has()` is true for the null case; inspecting the
    # value tag is not (it yields `!!null` for both absent and null).
    pr_target_present="$(read_workflow "${f}" '.on | has("pull_request_target")')" || true
    if [[ ${pr_target_present} == "true" ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: uses `pull_request_target` trigger (forbidden — base-ref workflow with head-ref code + full secrets)\n' \
        "${f}" >&2
      failed=$((failed + 1))
    fi
    ;;
  *)
    printf '%s: on: has unexpected shape (tag=%s)\n' "${f}" "${on_tag}" >&2
    failed=$((failed + 1))
    ;;
  esac
done
shopt -u nullglob

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d workflow(s) use forbidden `pull_request_target` trigger\n' "${failed}" >&2
  exit 1
fi
exit 0
