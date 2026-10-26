#!/usr/bin/env bash
# scripts/check-harden-runner-block.sh
#
# @description Lint: every step-security/harden-runner step uses
# egress-policy: block with a non-empty allowed-endpoints list,
# preventing network-level egress to unlisted hosts. Audit mode passes
# only under the comment linking the upstream block-mode bug.

# Asserts every step-security/harden-runner step in
# .github/workflows/*.yml uses egress-policy: block with a non-empty
# allowed-endpoints list, locking in that posture so no step reverts
# to audit or ships an empty allowlist — see docs/security/trust-model.md.
# One exception: `egress-policy: audit` passes when the key's head
# comment links https://github.com/step-security/harden-runner/issues/708,
# the upstream bug that makes block mode drop allowed hosts on westus2
# runners. The allowlist must still be non-empty there. Delete the
# exception when block mode returns.
# A step is a harden-runner step when its `uses:` holds
# `step-security/harden-runner@`, its ASCII letters in either case.
#
# A step `uses:`, `egress-policy` or `allowed-endpoints` written as a
# YAML alias is read as its anchored text.
#
# A job key the job list cannot carry (see scripts/lib/job-keys.sh) is a
# counted finding, and the file's jobs are not read.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift, 2 if yq is missing.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/ascii-match.sh
source "${_lib_dir}/lib/ascii-match.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

# The owner and repository of a harden-runner step, with each ASCII
# letter in either case, so a respelling does not take a step out of the
# lint's reach.
HARDEN_RUNNER_RE="$(ascii_fold_regex step-security/harden-runner)@"
readonly HARDEN_RUNNER_RE
# The upstream issue a temporary audit-mode step must link in the head
# comment of its egress-policy key. The comment is read as an array's
# first element because `key` on an absent key yields no value at all,
# which would drop the step's whole row from the read.
readonly AUDIT_MARKER_RE='github[.]com/step-security/harden-runner/issues/708'

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
  # A refused job key is a finding, and the rows below name a job by its
  # key, which such a key would split or hide. The read prints one line
  # per document.
  if ! odd_keys="$(first_odd_job_key "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  odd_key=''
  while IFS= read -r line; do
    if [[ -n ${line} ]]; then
      odd_key="${line}"
      break
    fi
  done <<<"${odd_keys}"
  if [[ -n ${odd_key} ]]; then
    odd_job_key_message "${f}" "${odd_key}" >&2
    failed=$((failed + 1))
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
  # The value is the last field because tab is IFS whitespace: an empty
  # field before another would collapse and shift the next one into it.
  # shellcheck disable=SC2016 # $j is a yq variable inside single-quoted yq expression
  if ! rows="$(yq eval "${YQ_MERGE_SPEC[@]}" "${JOBS_NODE}"'
    | to_entries[] as $j
    | $j.value.steps[]
    | select((.uses | explode(.)) // "" | test("'"${HARDEN_RUNNER_RE}"'"))
    | ($j.key | explode(.) | tostring) + "\t" + ((.with."egress-policy" | explode(.)) // "null") + "\t" + (([.with."egress-policy" | key | head_comment] | .[0]) // "" | tostring | test("'"${AUDIT_MARKER_RE}"'") | tostring) + "\t" + (((.with."allowed-endpoints" | explode(.)) // "null") | sub("\n"; " "))
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed, or non-string allowed-endpoints?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  while IFS=$'\t' read -r job policy marked endpoints; do
    [[ -z ${job} ]] && continue
    if [[ ${policy} == "audit" && ${marked} == "true" ]]; then
      :
    elif [[ ${policy} != "block" ]]; then
      printf '%s: job %q harden-runner egress-policy %q is not block\n' "${f}" "${job}" "${policy}" >&2
      failed=$((failed + 1))
      continue
    fi
    trimmed="${endpoints//[$' \t\n']/}"
    if [[ ${endpoints} == "null" || -z ${trimmed} ]]; then
      printf '%s: job %q has %s mode but empty allowed-endpoints\n' "${f}" "${job}" "${policy}" >&2
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
