#!/usr/bin/env bash
# scripts/check-checkout-persist-credentials.sh
#
# @description Lint: every `actions/checkout` step in every workflow
# sets `with.persist-credentials: false` so the GITHUB_TOKEN is not
# left in `.git/config` for subsequent steps to read.

# Lint: every `actions/checkout` step in every workflow under
# `.github/workflows/*.yml` sets `with.persist-credentials: false`.
#
# Without that setting, `actions/checkout` writes the GITHUB_TOKEN
# into `.git/config` and leaves it on disk for the remainder of the
# job. Any subsequent step in the same job — including a third-party
# action or a shell injection in a `run:` — can read the token from
# the working tree.
#
# The check matches `uses:` lines that start with `actions/checkout@`
# (any ref shape). For each match, `with.persist-credentials` must
# be present and exactly the boolean `false`: a scalar carrying the
# boolean tag whose text is `false`. Strings ("false"), missing keys,
# `true` and any other shape all fail, and so does a `with:` that is
# not a map. A job, its steps, a step, its `with:` and the value
# written as aliases are read through them; `jobs:` too. A job id that
# is not a scalar, is empty, holds a tab, a line break or a NUL, or is a
# merge key (`<<`) is a finding, and that workflow's jobs are not read.
# A merge list inside a job is read first mapping wins, as the YAML merge
# specification says (`YQ_MERGE_SPEC`). The value is compared
# whole, as JSON text, so one holding a line break cannot end its row
# early.
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

# @description Print a JSON string's text when it holds no escape or
# quote, else the JSON string itself, so a plain value reads as written
# and any other is shown unambiguously.
# @arg $1 a JSON string
function json_text() {
  if [[ $1 =~ ^\"([^\"\\]*)\"$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$1"
  fi
}

failed=0
shopt -s nullglob
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue

  # The steps are read below as tab-separated rows, and the job id is
  # the one field written as raw text, so an id that is not a scalar, is
  # empty, holds a tab, a line break or a NUL, or is a merge key could
  # forge, split or garble a row, or hide the jobs it brings in. GitHub
  # Actions refuses such an id, so it is a finding
  # and the workflow's jobs are not read. Each key is resolved through an
  # alias first, then tested as the text it renders to, whatever its
  # tag. The read prints, per document, the first such id's kind, and
  # its text as JSON (`-` for none).
  if ! odd_ids="$(yq eval "${YQ_MERGE_SPEC[@]}" "[${JOBS_NODE}"' | select(kind == "map") | keys[] | explode(.) | select(tag == "!!merge" or kind != "scalar" or (tostring | test("^$|[\t\n\x00]"))) | "kind=" + kind + ", id=" + (tostring | to_json(0))] | .[0] // "-"' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  odd_id=''
  while IFS= read -r line; do
    if [[ ${line} != '-' ]]; then
      odd_id="${line}"
      break
    fi
  done <<<"${odd_ids}"
  if [[ -n ${odd_id} ]]; then
    printf '%s: jobs: holds a job id that is not a scalar, is empty, holds a tab, a line break or a NUL, or is a merge key, which GitHub Actions refuses; its jobs are not read (first: %s)\n' \
      "${f}" "${odd_id}" >&2
    failed=$((failed + 1))
    continue
  fi

  # A `steps:` that is not a list holds no step to read; GitHub Actions
  # refuses such a job.
  # Each row: the step's index; the job id; `with` when the step's
  # `with:` is present but not a map, else `value`; then the kind of
  # that node (`none` when absent), and its tag and text as JSON
  # strings. A tag is free text (a verbatim tag decodes `%7C` to a pipe
  # and `%0A` to a line break), as is a value, and JSON holds neither a
  # tab nor a line break, so no field but the id can split a row, and
  # none is empty for `read` to collapse. The job is handed to `explode`
  # twice and each step three times more, so a job, its steps, a step,
  # its `with:` and the value written as aliases are read through them.
  # A `with:` map is read whatever tag it carries; the value is a scalar
  # told apart by its tag. Each value a row reads is collected into a
  # list with a default appended, and the row opens with an operand that
  # reads the step, because after a `select` that keeps nothing `yq`
  # still prints an expression made only of variables, literals and
  # collections.
  #
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  # shellcheck disable=SC2016 # yq expression: literal $ refs, not shell expansion
  if ! rows="$(yq eval --no-doc "${YQ_MERGE_SPEC[@]}" "${JOBS_NODE}"' | to_entries[] | (.key | explode(.) | tostring) as $k
    | .value | explode(.) | explode(.) | [.steps] | .[] | select(kind == "seq") | to_entries[]
    | select(.value | explode(.) | explode(.) | explode(.) | (.uses // "") | test("^actions/checkout@"))
    | (.key | tostring) + "\t" + $k + "\t" + (.value | explode(.) | explode(.) | explode(.) |
        [.with | select(kind != "map" and tag != "!!null") | "with\t" + kind + "\t" + (tag | to_json(0)) + "\t" + (tostring | to_json(0))]
        + [[.with | select(kind == "map") | ."persist-credentials"] | .[] | "value\t" + kind + "\t" + (tag | to_json(0)) + "\t" + (tostring | to_json(0))]
        + ["value\tnone\t\"\"\t\"\""] | .[0])
  ' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  [[ -n ${rows} ]] || continue
  while IFS=$'\t' read -r idx job node kind tag val; do
    [[ -z ${job} ]] && continue
    if [[ ${node} == 'with' ]]; then
      printf '%s: job %q step[%s] actions/checkout with: has unexpected shape (kind=%s, tag=%s, value=%s); must be a map holding persist-credentials: false\n' \
        "${f}" "${job}" "${idx}" "${kind}" "${tag}" "${val}" >&2
      failed=$((failed + 1))
      continue
    fi
    case "${kind} ${tag}" in
    'none '* | 'scalar "!!null"')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q step[%s] actions/checkout missing `with.persist-credentials: false`\n' \
        "${f}" "${job}" "${idx}" >&2
      failed=$((failed + 1))
      ;;
    'scalar "!!bool"')
      if [[ ${val} != '"false"' ]]; then
        # shellcheck disable=SC2016 # literal backticks in human-readable prose
        printf '%s: job %q step[%s] actions/checkout has `persist-credentials: %s`; must be `false`\n' \
          "${f}" "${job}" "${idx}" "$(json_text "${val}")" >&2
        failed=$((failed + 1))
      fi
      ;;
    'scalar "!!str"')
      # shellcheck disable=SC2016 # literal backticks in human-readable prose
      printf '%s: job %q step[%s] actions/checkout has string `persist-credentials: %q`; must be boolean `false`\n' \
        "${f}" "${job}" "${idx}" "$(json_text "${val}")" >&2
      failed=$((failed + 1))
      ;;
    *)
      printf '%s: job %q step[%s] actions/checkout persist-credentials has unexpected shape (kind=%s, tag=%s, value=%s); must be boolean false\n' \
        "${f}" "${job}" "${idx}" "${kind}" "${tag}" "${val}" >&2
      failed=$((failed + 1))
      ;;
    esac
  done <<<"${rows}"
done
shopt -u nullglob

if ((failed > 0)); then
  # shellcheck disable=SC2016 # literal backticks in human-readable prose
  printf '%d actions/checkout step(s) missing `persist-credentials: false`\n' "${failed}" >&2
  exit 1
fi
exit 0
