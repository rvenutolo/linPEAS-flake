#!/usr/bin/env bash
# scripts/check-notify-label-descriptions.sh
#
# @description Lint: every `label-description` handed to the
# notify-workflow-result composite fits GitHub's 100-character label
# description cap, and no label name carries two different descriptions
# across the workflows that file it.

# The composite writes the description onto the label: on creation, and
# on any later run where the live label's description differs. Both
# assertions below exist because that write is the one the maintainer
# reading a label sees.
#
#   1. Length — the labels API rejects a description over 100 characters
#      with a 422. An over-length value in a workflow can therefore never
#      reach the label it describes: the label keeps whatever wording it
#      was created with, and every run re-attempts the write and warns.
#      The tree looks like the source of truth and is not one.
#   2. Agreement — two workflows filing the same label with different
#      descriptions each rewrite the other's wording on every run, so the
#      description a maintainer sees is whichever workflow ran last.
#
# Honors WORKFLOWS_DIR_OVERRIDE (default: .github/workflows) and
# LINT_ALLOW_EMPTY_SCAN=1 for fixtures.
#
# Exits 0 when every description fits and agrees, 1 on a violation, 2
# when the check cannot run: `yq` absent from PATH, a workflow `yq`
# cannot parse, or a scan set naming no notify caller.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

# Every read below goes through yq, and a yq that is not there fails the
# first read. Scored as "no caller declares a description", that reading
# exits 0 having examined nothing.
require_tool yq

readonly WORKFLOWS_DIR="${WORKFLOWS_DIR_OVERRIDE:-.github/workflows}"
# GitHub's labels API caps a description at 100 characters.
readonly MAX_DESCRIPTION=100

# The composite is referenced two ways: the local path, and a pinned
# self-reference for the workflows that must resolve it at a fixed SHA.
# Matching on the trailing path segment covers both without pinning this
# lint to either spelling.
readonly COMPOSITE_SUFFIX='.github/actions/notify-workflow-result'

function main() {
  local -a workflows=()
  glob_into workflows "${WORKFLOWS_DIR}/*.yml" "${WORKFLOWS_DIR}/*.yml"
  if ((${#workflows[@]} == 0)); then
    printf 'notify-label-descriptions lint: empty scan set allowed\n'
    exit 0
  fi

  local failed=0 pairs='' callers=0
  local wf out
  for wf in "${workflows[@]}"; do
    # A workflow yq cannot parse is a workflow this lint did not read.
    # Left to `set -e` it would end the run under yq's status, which the
    # exit-code convention reads as a violation found rather than as a
    # file that was never examined.
    if ! out="$(yq eval "
      [ .jobs[].steps[]
        | select(.uses // \"\" | test(\"${COMPOSITE_SUFFIX}(@|\$)\"))
        | select(.with.\"label-description\" != null)
        | (.with.label // \"-\") + \"\t\" + .with.\"label-description\" ]
      | .[]
    " "${wf}" 2>/dev/null)"; then
      printf 'notify-label-descriptions lint: %s could not be parsed\n' "${wf}" >&2
      exit 2
    fi
    [[ -z ${out} ]] && continue
    callers=$((callers + 1))

    local line label description
    while IFS= read -r line; do
      [[ -z ${line} ]] && continue
      label="${line%%$'\t'*}"
      description="${line#*$'\t'}"
      if ((${#description} > MAX_DESCRIPTION)); then
        printf 'notify-label-descriptions lint: %s: label %s description is %d characters, over the %d-character cap\n' \
          "${wf}" "${label}" "${#description}" "${MAX_DESCRIPTION}" >&2
        failed=1
      fi
      pairs+="${label}"$'\t'"${description}"$'\n'
    done <<<"${out}"
  done

  # A scan set that matched workflows but no notify caller means the
  # composite moved or was renamed, not that every description is fine.
  if ((callers == 0)); then
    if [[ ${LINT_ALLOW_EMPTY_SCAN:-} == 1 ]]; then
      printf 'notify-label-descriptions lint: no notify callers, allowed\n'
      exit 0
    fi
    printf 'notify-label-descriptions lint: %d workflow(s) scanned, none uses %s\n' \
      "${#workflows[@]}" "${COMPOSITE_SUFFIX}" >&2
    exit 2
  fi

  local conflicts
  conflicts="$(printf '%s' "${pairs}" | sort --unique |
    cut --fields=1 | uniq --repeated)"
  if [[ -n ${conflicts} ]]; then
    local label
    while IFS= read -r label; do
      [[ -z ${label} ]] && continue
      printf 'notify-label-descriptions lint: label %s is filed with more than one description\n' \
        "${label}" >&2
      failed=1
    done <<<"${conflicts}"
  fi

  if ((failed == 0)); then
    local checked
    checked="$(printf '%s' "${pairs}" | sort --unique | wc --lines)"
    printf 'notify-label-descriptions lint: %d label description(s) across %d caller workflow(s) within the %d-character cap and in agreement\n' \
      "${checked}" "${callers}" "${MAX_DESCRIPTION}"
  fi
  exit "${failed}"
}

main "$@"
