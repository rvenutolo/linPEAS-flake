#!/usr/bin/env bash
# scripts/check-harden-runner-first.sh
#
# @description Lint: every job in .github/workflows/*.yml begins
# with `step-security/harden-runner@<sha>` as its first step, so the
# eBPF monitor installs before any I/O.

# Asserts every job in .github/workflows/*.yml begins with
# `step-security/harden-runner@<sha>` as its first step. The eBPF
# monitor must install before any I/O, so this invariant is binding —
# see docs/security/trust-model.md.
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
  if ! rows="$(yq eval '.jobs | to_entries[] | .key + "\t" + (.value.steps[0].uses // "null")' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  while IFS=$'\t' read -r job first_uses; do
    [[ -z ${job} ]] && continue
    if [[ ${first_uses} == "null" || -z ${first_uses} ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q has no first-step `uses:` (need step-security/harden-runner@<sha>)\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
      continue
    fi
    if [[ ${first_uses} != step-security/harden-runner@* ]]; then
      printf '%s: job %q first step is %q, want step-security/harden-runner@<sha>\n' \
        "${f}" "${job}" "${first_uses}" >&2
      failed=$((failed + 1))
      continue
    fi
    if [[ ! ${first_uses} =~ ^step-security/harden-runner@[0-9a-f]{40}$ ]]; then
      printf '%s: job %q harden-runner ref %q not SHA-pinned\n' \
        "${f}" "${job}" "${first_uses}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d job(s) missing harden-runner as first step\n' "${failed}" >&2
  exit 1
fi
exit 0
