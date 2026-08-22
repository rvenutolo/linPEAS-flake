#!/usr/bin/env bash
# scripts/check-job-timeout-minutes.sh
#
# @description Lint: every job under .github/workflows/*.yml
# declares an explicit `timeout-minutes`, bounding blast radius
# from hung jobs. Reusable-workflow jobs are exempt.

# Lint: every job under .github/workflows/*.yml declares
# `timeout-minutes`. The default GitHub Actions job timeout is 6 hours,
# which lets a hung job burn the runner budget and stall the merge
# queue. Requiring an explicit per-job value bounds blast radius.
#
# A job satisfies the lint when `.jobs.<name>.timeout-minutes` is an
# integer scalar. Reusable-workflow jobs (those calling another
# workflow via `uses:`) are exempt because `timeout-minutes` is not
# valid on that shape.
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

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  if ! rows="$(yq eval '.jobs | to_entries[] | .key + "|" + (.value.uses | tag) + "|" + (.value."timeout-minutes" | tag) + "|" + (.value."timeout-minutes" | tostring)' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  while IFS='|' read -r job uses_tag timeout_tag timeout_val; do
    [[ -z ${job} ]] && continue

    # Reusable-workflow jobs (uses: <ref>) don't accept timeout-minutes.
    if [[ ${uses_tag} == "!!str" ]]; then
      continue
    fi

    case "${timeout_tag}" in
    '!!null')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q missing `timeout-minutes` (default is 6h; declare an explicit value)\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
      ;;
    '!!int')
      if [[ ${timeout_val} -le 0 ]]; then
        printf '%s: job %q timeout-minutes must be positive (got %s)\n' \
          "${f}" "${job}" "${timeout_val}" >&2
        failed=$((failed + 1))
      fi
      ;;
    *)
      printf '%s: job %q timeout-minutes has unexpected shape (tag=%s, value=%s); expected integer\n' \
        "${f}" "${job}" "${timeout_tag}" "${timeout_val}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d job(s) missing or invalid timeout-minutes\n' "${failed}" >&2
  exit 1
fi
exit 0
