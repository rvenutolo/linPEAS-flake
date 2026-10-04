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
# A job satisfies the lint when `.jobs.<name>.timeout-minutes` is a
# scalar carrying the integer tag, written in decimal digits, and not
# zero. Any other value is reported with its kind, tag and text. The
# value is compared as text, never as a shell number, so a value bash
# would read as an expression is never evaluated. Reusable-workflow jobs
# (those whose `uses:` is a scalar carrying the string tag) are exempt
# because `timeout-minutes` is not valid on that shape. A job, its
# `uses:` and its `timeout-minutes:` written as aliases are read through
# them, as is a job id. A job id that is not a scalar, is empty, or
# holds a tab or a line break is a finding, whatever its tag: GitHub
# Actions refuses such an id, and it could forge, split or garble the
# tab-separated row the jobs are read through, so that workflow's jobs
# are not read.
#
# No read stops the run. Each can fail on the workflow's own content (an
# unparsable file fails the first, `jobs: 5` the second), and a failure
# is a finding against the file, with the scan going on.
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

  # The jobs are read below as tab-separated rows, and the job id is the
  # one field written as raw text, so an id that is not a scalar, is
  # empty, or holds a tab or a line break could forge, split or garble a
  # row. Each key is resolved through an alias first, then tested as the
  # text it renders to, whatever its tag; a document whose `jobs:` is not
  # a map has no ids to test.
  if ! odd_ids="$(yq eval '[.jobs | select(kind == "map") | keys[] | explode(.) | select(kind != "scalar" or (tostring | test("^$|[\t\n]")))] | length' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  # One count per document: any count above 0 is a finding.
  if [[ ${odd_ids} == *[1-9]* ]]; then
    printf '%s: jobs: holds a job id that is not a string, is empty, or holds a tab or a line break, which GitHub Actions refuses; its jobs are not read\n' \
      "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  # Each row: the job id, resolved through an alias; whether its `uses:` is a scalar carrying the
  # string tag; the kind of its `timeout-minutes:` (`none` when absent);
  # the value when it is a scalar carrying the integer tag and written in
  # decimal digits (`-` otherwise); and the value's tag and text as JSON
  # strings. A tag is free text too (a verbatim tag decodes `%7C` to a
  # pipe and `%0A` to a line break), and JSON holds neither a tab nor a
  # line break, so no field but the id can split a row, and no field is
  # empty for `read` to collapse. The job is handed to `explode` twice,
  # so a job written as an alias and an alias inside it are both read
  # through (an anchor cannot sit on an alias). Each node is collected
  # into a list first, since `yq` yields nothing at all for an absent key.
  #
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  if ! rows="$(yq eval '.jobs | to_entries[] | (.key | explode(.) | tostring) + "\t" + (.value | explode(.) | explode(.) | ([.uses | select((kind == "scalar") and (tag == "!!str"))] | length > 0 | tostring) + "\t" + ([."timeout-minutes" | kind + "\t" + ((select((kind == "scalar") and (tag == "!!int")) | tostring | select(test("^[0-9]+$"))) // "-") + "\t" + (tag | to_json(0)) + "\t" + (tostring | to_json(0))] + ["none\t-\t\"\"\t\"\""] | .[0]))' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi

  while IFS=$'\t' read -r job reusable timeout_kind timeout_digits timeout_tag timeout_text; do
    [[ -z ${job} ]] && continue
    # Every field is printed non-empty, so an empty one is a row this
    # loop cannot read, which is a finding rather than a pass.
    if [[ -z ${timeout_text} || (${reusable} != true && ${reusable} != false) ]]; then
      printf '%s: job %q: cannot read its uses: and timeout-minutes:\n' "${f}" "${job}" >&2
      failed=$((failed + 1))
      continue
    fi

    # Reusable-workflow jobs (uses: <ref>) don't accept timeout-minutes.
    if [[ ${reusable} == 'true' ]]; then
      continue
    fi

    # An absent key, or one carrying the null tag (which yq reads as a
    # null scalar whatever it is written on), is a missing one.
    if [[ ${timeout_kind} == 'none' || ${timeout_tag} == '"!!null"' ]]; then
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q missing `timeout-minutes` (default is 6h; declare an explicit value)\n' \
        "${f}" "${job}" >&2
      failed=$((failed + 1))
    elif [[ ${timeout_digits} == '-' ]]; then
      printf '%s: job %q timeout-minutes has unexpected shape (kind=%s, tag=%s, value=%s); expected an integer in decimal digits\n' \
        "${f}" "${job}" "${timeout_kind}" "${timeout_tag}" "${timeout_text}" >&2
      failed=$((failed + 1))
    elif [[ ${timeout_digits} =~ ^0+$ ]]; then
      printf '%s: job %q timeout-minutes must be positive (got %s)\n' \
        "${f}" "${job}" "${timeout_digits}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d job(s) missing or invalid timeout-minutes\n' "${failed}" >&2
  exit 1
fi
exit 0
