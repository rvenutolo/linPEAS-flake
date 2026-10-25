#!/usr/bin/env bash
# scripts/check-auto-merge-decline-gate.sh
#
# @description Lint: every workflow run-block that calls `gh pr merge`
# with `--auto` must also carry the decline gate (a `gh pr view --json
# state` query plus `CLOSED|MERGED` case arms that each carry `exit 1`
# before their `;;`), so a maintainer-closed (declined) or already-merged
# PR is never silently resurrected by an auto-merging update workflow.

# An auto-merging update workflow recreates a per-period branch and
# calls `gh pr merge --auto`. Without inspecting PR state first, a
# re-run in the same period overwrites a PR the maintainer explicitly
# CLOSED (declined) or one already MERGED. The decline gate queries
# `gh pr view --json state` and aborts non-zero on CLOSED|MERGED. A PR
# the workflow's own App closed is recreated inside that arm instead,
# which this textual check neither requires nor forbids.
#
# This lint hard-fails if any `--auto` merge run-block lacks that gate,
# foreclosing drift between sibling auto-merge workflows.
#
# Detection is textual, not a full shell parse: a run-block invoking
# `gh pr merge ... --auto` must also contain `--json state`, at least one
# `CLOSED|MERGED)` case arm, and `exit 1` inside every such arm, between
# its label and the `;;` that ends it. An `exit 1` elsewhere in the block,
# one in a comment, or an exit with another status does not satisfy it.
# A run-block written as an alias (`run: *body`) is read as its anchored
# text.
#
# A job key the job list cannot carry (see scripts/lib/job-keys.sh) is a
# finding and that workflow's jobs are not read. `jobs:` is read as
# `JOBS_NODE`, so a root key written as an alias of `jobs` is read, and
# one given twice is a workflow `yq` cannot evaluate. A merge list inside a
# job is read first mapping wins, as the YAML merge specification says
# (`YQ_MERGE_SPEC`).
#
# See docs/security/workflow-hardening.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift, 2 on tooling error.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly DIR="${OVERRIDE:-${DEFAULT_DIR}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi

# Exits 0 when the block holds at least one `CLOSED|MERGED)` case arm and
# every such arm carries `exit 1` between its label and the `;;` that ends
# it. Text after a `#` that starts a word is a comment and is dropped
# first, so a commented-out exit does not count. An arm with no `;;`
# before the block ends counts as one that does not exit. The scan is
# textual: an arm whose body holds a nested `case` ends at that nested
# arm's `;;`, which reads as the arm ending early and fails closed.
# shellcheck disable=SC2016 # awk program literal; its $ names are awk fields
readonly ARM_EXITS_PROGRAM='
  {
    line = $0
    sub(/(^|[[:space:]])#.*/, "", line)
    while (line != "") {
      if (!in_arm) {
        if (!match(line, /(^|[[:space:](])CLOSED[|]MERGED[)]/)) break
        arms++
        in_arm = 1
        exits = 0
        line = substr(line, RSTART + RLENGTH)
      }
      end = index(line, ";;")
      seg = end ? substr(line, 1, end - 1) : line
      if (seg ~ /(^|[^[:alnum:]_])exit[[:space:]]+1([^[:alnum:]_]|$)/) exits = 1
      if (!end) break
      if (!exits) bad++
      in_arm = 0
      line = substr(line, end + 2)
    }
  }
  END {
    if (in_arm) bad++
    exit (arms > 0 && bad == 0) ? 0 : 1
  }
'

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  # A job key the job list cannot carry would hide the jobs behind it
  # from the read below, so it is a finding and the jobs are not read.
  if ! odd_key="$(first_odd_job_key "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  if [[ -n ${odd_key} ]]; then
    odd_job_key_message "${f}" "${odd_key}" >&2
    failed=$((failed + 1))
    continue
  fi

  # Capture yq's output into a temp file rather than feeding the loop
  # from `< <(yq ...)`: a process substitution's exit status is not
  # propagated under set -Eeuo pipefail, so a yq parse failure would
  # yield empty input and the file would pass wholesale. NUL-delimited
  # output cannot round-trip through "$(...)" (bash command substitution
  # strips embedded NUL bytes), hence the temp file.
  runs_file="$(make_temp)"
  if ! yq eval "${YQ_MERGE_SPEC[@]}" -0 "${JOBS_NODE}"' | .[].steps[] | (.run // "") | explode(.)' "${f}" >"${runs_file}"; then
    rm --force -- "${runs_file}"
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  # Each step run: scalar, NUL-delimited so multi-line blocks stay
  # intact. `// ""` keeps null runs from emitting the literal "null". A
  # body written as an alias (`run: *body`) is exploded to its anchored
  # text, which is what the runner executes; read as is it would be the
  # alias name.
  while IFS= read -r -d '' block; do
    [[ -n ${block} ]] || continue
    # Only auto-merge run-blocks are in scope.
    grep -Eq 'gh[[:space:]]+pr[[:space:]]+merge' <<<"${block}" || continue
    grep -Eq -- '--auto' <<<"${block}" || continue
    # Required gate signature, all within this same run-block.
    if grep -q -- '--json state' <<<"${block}" &&
      grep -Eq 'CLOSED\|MERGED' <<<"${block}" &&
      LC_ALL=C awk "${ARM_EXITS_PROGRAM}" <<<"${block}"; then
      continue
    fi
    printf '%s: auto-merge run-block missing CLOSED|MERGED decline gate\n' "${f}" >&2
    failed=$((failed + 1))
  done <"${runs_file}"
  rm --force -- "${runs_file}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d auto-merge run-block(s) missing the decline gate\n' "${failed}" >&2
  exit 1
fi
exit 0
