#!/usr/bin/env bash
# scripts/check-harden-runner-block.sh
#
# @description Lint: every step-security/harden-runner step uses
# egress-policy: block with a non-empty allowed-endpoints list,
# preventing network-level egress to unlisted hosts.

# Asserts every step-security/harden-runner step in
# .github/workflows/*.yml uses egress-policy: block with a non-empty
# allowed-endpoints list, locking in that posture so no step reverts
# to audit or ships an empty allowlist — see docs/security/trust-model.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift, 2 if yq is missing.

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
for f in "${workflow_files[@]}"; do
  [[ -f ${f} ]] || continue
  if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
    continue
  fi
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # would yield empty input and the check would pass silently. This bites
  # on a valid workflow whose `allowed-endpoints` is a YAML sequence: the
  # string-concat query aborts with "!!seq cannot be added to !!str".
  #
  # Newlines in the `allowed-endpoints` value are collapsed to spaces: a
  # literal block scalar (`allowed-endpoints: |`) carries real newlines,
  # and the reader below is line-oriented, so an uncollapsed value would
  # split one step into several bogus records. The check only needs to
  # know whether the value is non-empty, so the separator is irrelevant.
  # shellcheck disable=SC2016 # $j is a yq variable inside single-quoted yq expression
  if ! rows="$(yq eval '
    .jobs | to_entries[] as $j
    | $j.value.steps[]
    | select(.uses // "" | test("step-security/harden-runner@"))
    | $j.key + "\t" + (.with."egress-policy" // "null") + "\t" + ((.with."allowed-endpoints" // "null") | sub("\n"; " "))
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed, or non-string allowed-endpoints?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  while IFS=$'\t' read -r job policy endpoints; do
    [[ -z ${job} ]] && continue
    if [[ ${policy} != "block" ]]; then
      printf '%s: job %q harden-runner egress-policy %q is not block\n' "${f}" "${job}" "${policy}" >&2
      failed=$((failed + 1))
      continue
    fi
    trimmed="${endpoints//[$' \t\n']/}"
    if [[ ${endpoints} == "null" || -z ${trimmed} ]]; then
      printf '%s: job %q has block mode but empty allowed-endpoints\n' "${f}" "${job}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d harden-runner step(s) not in block mode with non-empty allowed-endpoints\n' "${failed}" >&2
  exit 1
fi
exit 0
