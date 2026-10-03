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
# Every read starts from the `on:` node as ON_NODE below builds it: the
# one root key that is `on` or an alias of `on`, passed through
# `explode` sixteen times. A root with more than one such key, or an
# `on:` still holding an alias after the passes, is refused as a
# workflow `yq` cannot read.
# A merge key, which `actionlint` reports as unsupported by GitHub
# Actions, is resolved by `yq`'s rule, and `yq` prints a warning of its
# own on stderr when it resolves one.
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift. Exits 2 when the check
# cannot run: `yq` is absent from PATH, the workflow globs match no
# file, WORKFLOW_FILE_FILTER selects none of the files they matched, or
# a `yq` read fails for a workflow whose first read succeeded, which a
# node whose tag `yq` cannot decode does too. The first read, of the
# `pull_request` trigger, stays a counted finding when it fails, and the
# workflow's `push` trigger is then not read. An empty scan set is a
# could-not-run rather than a clean tree; LINT_ALLOW_EMPTY_SCAN=1 accepts
# one deliberately.

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

# @description Stop the run on a `yq` read that failed after the
# workflow's first read succeeded. The file parses, so the failure is
# usually `yq` failing. A node whose tag `yq` cannot decode
# (`push: !!map [a]`), or a branch list it cannot render as JSON
# (`branches: [.nan]`), fails such a read too, and is reported the same
# way, though it is a fact about the workflow. Carrying on would
# compare an empty value and score the trigger absent.
# @arg $1 what was being read
# @arg $2 workflow path
# @arg $3 the status `yq` exited with
# @exitcode 2 always
function die_unread() {
  printf 'cannot read %s of %s: yq exited %d\n' "$1" "$2" "$3" >&2
  exit 2
}

# The `on:` node every read starts from, with its aliases resolved. It
# is the one root key that is `on` or an alias of `on`: a root holding
# more than one makes `yq` fail ("on: is given more than once"). With no
# such key it is `.on`, which is how an `on:` a root merge key brings in
# is read, since the merged keys are not the root's own. Reading `.on`
# also makes a root that is a list fail the read; a scalar root fails
# when its keys are listed.
# `explode`, handed that node alone, resolves one level of aliases per
# pass: the aliases a node holds, not those inside what they stand for.
# So the node goes through sixteen passes, and one that still holds an
# alias after them is refused by `yq` with an error rather than read. A
# file `yq` reads through this is never passed with an alias left in it.
# Its memory cost is a stated limit: docs/development/linting.md, section
# "YAML aliases in workflow reads".
# shellcheck disable=SC2016 # yq program literal; its $ names are yq variables
readonly ON_NODE='.on as $plain | [to_entries[] | select((.key | explode(.)) == "on") | .value] as $all | with(select($all | length > 1); error("on: is given more than once")) | ($all + [$plain] | .[0]) as $n | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16][] as $i ireduce ($n; explode(.)) | with(select([... | select(kind == "alias")] | length > 0); error("on: holds an alias nested too deep to resolve"))'

# Check one trigger (pull_request / push) within one workflow file.
# Args: file, trigger-name, and 1 when an earlier read of the file has
# succeeded (0 for its first read).
# Returns 0 when the trigger is clean, 1 on a finding it has printed, and
# 3 when the file's first read failed: that is the counted finding
# read_workflow has printed, and the file is not read further. A later
# read that fails ends the run with exit 2 through die_unread.
check_trigger() {
  local -r file="$1" trigger="$2" read_before="$3"
  local trig_tag trig_present
  if ((read_before)); then
    trig_tag="$(yq eval "${ON_NODE} | .\"${trigger}\" | tag" "${file}")" ||
      die_unread "the on.${trigger} trigger" "${file}" "$?"
  else
    trig_tag="$(read_workflow "${file}" "${ON_NODE} | .\"${trigger}\" | tag")" || return 3
  fi
  case "${trig_tag}" in
  '!!null')
    # yq reports !!null for both an absent trigger and one that is
    # present with no value. A present-but-null trigger
    # (`pull_request:` with nothing under it) fires on every branch —
    # exactly the implicit all-branches this lint forbids — so treat
    # only the absent case as unaffected.
    trig_present="$(yq eval "${ON_NODE} | has(\"${trigger}\")" "${file}")" ||
      die_unread "the on.${trigger} key" "${file}" "$?"
    if [[ ${trig_present} == "true" ]]; then
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
  branches_tag="$(yq eval "${ON_NODE} | .\"${trigger}\".branches | tag" "${file}")" ||
    die_unread "the on.${trigger}.branches shape" "${file}" "$?"
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
  rendered="$(yq eval --output-format=json --indent=0 \
    "${ON_NODE} | .\"${trigger}\".branches" "${file}")" ||
    die_unread "the on.${trigger}.branches list" "${file}" "$?"
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
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  read_before=0
  for trigger in pull_request push; do
    trigger_status=0
    check_trigger "${f}" "${trigger}" "${read_before}" || trigger_status=$?
    if ((trigger_status == 3)); then
      failed=$((failed + 1))
      continue 2
    fi
    if ((trigger_status != 0)); then
      failed=$((failed + 1))
    fi
    read_before=1
  done
done
shopt -u nullglob

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d workflow trigger(s) missing or non-canonical `branches: [main]`\n' "${failed}" >&2
  exit 1
fi
exit 0
