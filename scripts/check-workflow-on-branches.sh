#!/usr/bin/env bash
# scripts/check-workflow-on-branches.sh
#
# @description Lint: every workflow declaring `on.pull_request:` or
# `on.push:` explicitly sets `branches: [main]` under that trigger
# — no wildcards, no implicit all-branches.

# Lint: every workflow that declares `on.pull_request:` or `on.push:`
# must explicitly set `branches: [main]` under that trigger. No
# wildcards, no implicit all-branches, no other branch names.
#
# Without the allowlist, GitHub Actions fires the workflow on every
# branch — burning runner minutes on stale topic branches and creating
# surprising activity (status checks attached to refs nobody is
# watching). Explicit `branches: [main]` is the project convention.
#
# Workflows that omit both `pull_request:` and `push:` (cron, manual,
# workflow_call only) are unaffected. `pull_request_target:` is out of
# scope here — a separate lint forbids it outright.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

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

# Check one trigger (pull_request / push) within one workflow file.
# Args: file, trigger-name
check_trigger() {
  local -r file="$1" trigger="$2"
  local trig_tag
  trig_tag="$(yq eval ".on.\"${trigger}\" | tag" "${file}")"
  case "${trig_tag}" in
  '!!null')
    # yq reports !!null for both an absent trigger and one that is
    # present with no value. A present-but-null trigger
    # (`pull_request:` with nothing under it) fires on every branch —
    # exactly the implicit all-branches this lint forbids — so treat
    # only the absent case as unaffected.
    if [[ "$(yq eval ".on | has(\"${trigger}\")" "${file}")" == "true" ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: on.%s is present but null (implicit all-branches forbidden; need `branches: [main]`)\n' \
        "${file}" "${trigger}" >&2
      return 1
    fi
    return 0
    ;;
  '!!map') ;;
  *)
    printf '%s: on.%s has unexpected shape (tag=%s); expected map\n' \
      "${file}" "${trigger}" "${trig_tag}" >&2
    return 1
    ;;
  esac

  local branches_tag
  branches_tag="$(yq eval ".on.\"${trigger}\".branches | tag" "${file}")"
  if [[ ${branches_tag} == "!!null" ]]; then
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: on.%s is missing `branches: [main]` (implicit all-branches forbidden)\n' \
      "${file}" "${trigger}" >&2
    return 1
  fi
  if [[ ${branches_tag} != "!!seq" ]]; then
    printf '%s: on.%s.branches has unexpected shape (tag=%s); expected sequence\n' \
      "${file}" "${trigger}" "${branches_tag}" >&2
    return 1
  fi

  local rendered
  rendered="$(yq eval --output-format=json --indent=0 ".on.\"${trigger}\".branches" "${file}")"
  if [[ ${rendered} != '["main"]' ]]; then
    # shellcheck disable=SC2016 # literal backticks in human-readable prose
    printf '%s: on.%s.branches must be exactly `[main]`; got %s\n' \
      "${file}" "${trigger}" "${rendered}" >&2
    return 1
  fi
  return 0
}

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
for f in "${workflow_files[@]}"; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi

  for trigger in pull_request push; do
    if ! check_trigger "${f}" "${trigger}"; then
      failed=$((failed + 1))
    fi
  done
done
shopt -u nullglob

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d workflow trigger(s) missing or non-canonical `branches: [main]`\n' "${failed}" >&2
  exit 1
fi
exit 0
