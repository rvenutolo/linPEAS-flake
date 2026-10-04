#!/usr/bin/env bash
# scripts/check-permission-scopes.sh
#
# @description Per-job GITHUB_TOKEN write-scope allowlist lint for
# GitHub Actions. Fails when a job grants a write scope absent from
# .github/permission-scopes.yml, when an allowlist entry is stale, or
# when an allowlist scope list is not sorted.

# Hand-maintained allowlist gate. .github/permission-scopes.yml is the
# source of truth for which *write* scopes each job may hold. For every
# .github/workflows/*.yml job this asserts:
#
#   1. Every scope the job grants with value `write` is listed under that
#      job in the allowlist. An un-listed write scope is an over-grant.
#   2. Every scope listed for the job in the allowlist is actually granted
#      `write` by the job, and every allowlist workflow/job exists. A
#      listed-but-absent scope (or a vanished workflow/job) is stale.
#   3. Every per-job scope list in the allowlist is sorted, so the
#      "sorted list of write-scope names" format documented in
#      docs/security/min-permissions.md stays enforced, diffs stay
#      minimal, and a duplicate-prone append-anywhere habit cannot form.
#
# A job's `permissions:` is read by its kind, through an alias. A map
# carrying a tag of its own is still read scope by scope. It may also be
# the string `read-all` (ignored), and a null or absent block yields
# nothing (min-permissions reports it missing; `yq` reads a block
# carrying the null tag as null whatever it is written on). Any other
# shape, such as the string `write-all` or a scalar carrying the map
# tag, is a violation (a scalar
# grant bypasses the per-scope allowlist entirely). A job id or a scope
# name that is not a scalar, is empty, or holds a tab, a line break or a
# NUL is a violation, and that workflow's jobs are not read.
#
# Read and `none` scope values are ignored — least-privilege concern is
# write over-grant. See docs/security/min-permissions.md.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER + SCOPE_ALLOWLIST_OVERRIDE
# for fixtures. Exit 0 clean, 1 on drift (including a scalar permissions
# violation or a workflow yq cannot parse), 2 on config/tooling error
# (including an allowlist file that does not parse or is not one map of
# workflow maps).

# $k/$wf/$job in the yq expressions below are yq variables, not shell.
# shellcheck disable=SC2016
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly DEFAULT_DIR=".github/workflows"
readonly DEFAULT_ALLOWLIST=".github/permission-scopes.yml"
readonly DIR="${WORKFLOWS_DIR_OVERRIDE:-${DEFAULT_DIR}}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"
readonly ALLOWLIST="${SCOPE_ALLOWLIST_OVERRIDE:-${DEFAULT_ALLOWLIST}}"

if ! command -v yq >/dev/null 2>&1; then
  printf 'yq not found on PATH\n' >&2
  exit 2
fi
if [[ ! -f ${ALLOWLIST} ]]; then
  printf 'allowlist file not found: %s\n' "${ALLOWLIST}" >&2
  exit 2
fi
# The lookups below walk the allowlist's entries, which a list would
# also have, keyed by index; so it must be one map whose entries are
# workflow maps or null.
if ! allowlist_shape="$(yq eval 'explode(.) | kind + " " + ([.[] | select(tag != "!!null") | kind] | unique | join(","))' "${ALLOWLIST}")"; then
  printf '%s: could not evaluate allowlist with yq (malformed?)\n' "${ALLOWLIST}" >&2
  exit 2
fi
if [[ ${allowlist_shape} != 'map map' && ${allowlist_shape} != 'map ' ]]; then
  printf '%s: the allowlist must be one map of workflow maps (got %q)\n' "${ALLOWLIST}" "${allowlist_shape}" >&2
  exit 2
fi

# allowed <workflow-basename> <job> -> newline-separated allowed scope names
# The names reach `yq` as data, through `strenv`, and are compared by
# their base64 text: spliced into the expression, a name holding a quote
# would be read as `yq` code, and `yq` reads `*` and `?` in an index or
# an `==` comparison as wildcards, which base64 text never holds.
# `explode` resolves merge keys and aliases first, and of names written
# twice the last is read, as `yq`'s own lookup reads it.
function allowed() {
  WF="$1" JOB="$2" yq eval 'explode(.) | [to_entries[] | '"$(eq WF)"'] | reverse | .[0] | .value | [to_entries[] | '"$(eq JOB)"'] | reverse | .[0] | .value // [] | .[]' "${ALLOWLIST}"
}

# eq <variable> -> a yq select keeping the entry whose key's text is the
# variable's, compared as base64 so neither side is read as a pattern.
function eq() {
  printf 'select((.key | tostring | @base64) == (strenv(%s) | @base64))' "$1"
}

# The `jobs:` node, read through an alias: `explode` handed only that
# node resolves it in one pass, since an anchor cannot sit on an alias.
readonly JOBS_NODE='[(.jobs | select(kind == "alias") | explode(.)), (.jobs | select(kind != "alias"))] | .[0]'

failed=0
shopt -s nullglob

# --- forward: workflow write scopes ⊆ allowlist -------------------------
declare -a workflow_files=()
glob_into workflow_files 'workflow YAML' "${DIR}/*.yml" "${DIR}/*.yaml"
declare -a selected_files=()
filter_into selected_files 'workflow YAML' "${FILE_FILTER}" "${workflow_files[@]}"
for f in "${selected_files[@]}"; do
  [[ -f ${f} ]] || continue
  base="$(basename "${f}")"
  # The rows below are tab-separated, with the job id and the scope name
  # written as raw text, so an id or a scope name that is not a scalar,
  # is empty, or holds a tab, a line break or a NUL could forge, split or
  # garble a row. GitHub Actions refuses such a name, so it is a finding
  # and the workflow's jobs are not read. Each name is resolved through
  # an alias first, then tested as the text it renders to, whatever its
  # tag. The read prints, per document, the first such name's kind, and
  # its text as JSON (`-` for none).
  if ! odd_names="$(yq eval "[${JOBS_NODE}"' | select(kind == "map") | to_entries[] | ((.key | explode(.)), (.value | explode(.) | explode(.) | explode(.) | [.permissions] | .[] | select(kind == "map") | keys[] | explode(.))) | select(kind != "scalar" or (tostring | test("^$|[\t\n\x00]"))) | "kind=" + kind + ", name=" + (tostring | to_json(0))] | .[0] // "-"' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  odd_name=''
  while IFS= read -r line; do
    if [[ ${line} != '-' ]]; then
      odd_name="${line}"
      break
    fi
  done <<<"${odd_names}"
  if [[ -n ${odd_name} ]]; then
    printf '%s: jobs: holds a job id or a scope name that is not a scalar, is empty, or holds a tab, a line break or a NUL, which GitHub Actions refuses; its jobs are not read (first: %s)\n' \
      "${f}" "${odd_name}" >&2
    failed=$((failed + 1))
    continue
  fi
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # (unparsable workflow, or a query that errors on a valid-but-odd
  # shape) would yield empty input and the check would pass silently.
  #
  # A job's `permissions:` is read by its kind, through an alias: the job
  # is handed to `explode` three times, so a job written as an alias, its
  # `permissions:` and a scope's value each resolve. A map, whatever tag
  # it carries, yields one row per scope it grants `write`. The string
  # `read-all` (a scalar carrying the string tag) and a null or absent
  # block yield nothing. Any other shape yields a row with its kind, and
  # its tag and text as JSON strings, which hold no tab or line break;
  # the loop reports it as a violation instead of letting it abort the
  # yq stream mid-file. Every expression after a `select` reads `.`,
  # since one that does not prints even when the `select` keeps nothing.
  if ! rows="$(yq eval --no-doc "${JOBS_NODE}"' | to_entries[] | (.key | explode(.) | tostring) as $k | (.value | explode(.) | explode(.) | explode(.) | [.permissions] | .[])
    | ( (select(kind == "map") | to_entries[] | select(.value == "write") | $k + "\tW\t" + (.key | tostring)),
        (select(kind != "map") | select(tag != "!!null") | select((kind == "scalar" and tag == "!!str" and . == "read-all") | not)
          | $k + "\tS\t" + kind + "\t" + (tag | to_json(0)) + "\t" + (tostring | to_json(0))) )' "${f}")"; then
    printf '%s: could not evaluate workflow with yq (malformed?)\n' "${f}" >&2
    failed=$((failed + 1))
    continue
  fi
  [[ -n ${rows} ]] || continue
  while IFS=$'\t' read -r job row_kind scope shape_tag shape_text; do
    [[ -z ${job} ]] && continue
    if [[ ${row_kind} == "S" ]]; then
      if [[ ${scope} == "scalar" && ${shape_tag} == '"!!str"' ]]; then
        printf '%s: job %q uses scalar permissions %s (only read-all is allowed as a scalar)\n' \
          "${f}" "${job}" "${shape_text}" >&2
      else
        printf '%s: job %q permissions has unexpected shape (kind=%s, tag=%s, value=%s); only a map or the string read-all is allowed\n' \
          "${f}" "${job}" "${scope}" "${shape_tag}" "${shape_text}" >&2
      fi
      failed=$((failed + 1))
      continue
    fi
    # Capture the allowlist read (and its exit status) into a variable
    # rather than feeding the here-string from `<<<"$(allowed ...)"`: a
    # command substitution's exit status is not propagated into the
    # command it feeds, so a yq failure yields an empty scope list and
    # every write scope in the workflow is reported as an over-grant
    # against an allowlist nothing read. The allowlist is a precondition
    # file, not a scanned artifact, so an unparsable one is a tooling
    # error (exit 2); an unparsable workflow stays a finding.
    if ! allowed_scopes="$(allowed "${base}" "${job}")"; then
      printf '%s: could not evaluate allowlist with yq (malformed?)\n' \
        "${ALLOWLIST}" >&2
      exit 2
    fi
    if ! grep -qxF "${scope}" <<<"${allowed_scopes}"; then
      printf '%s: job %q grants write scope %q not allowed by %s\n' \
        "${f}" "${job}" "${scope}" "${ALLOWLIST}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${rows}"
done

# --- reverse: allowlist entries are not stale ---------------------------
# Skip when filtered to a single fixture (the allowlist names other fixtures).
if [[ -z ${FILE_FILTER} ]]; then
  # Capture yq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(yq ...)`: a process substitution's exit
  # status is not propagated under set -Eeuo pipefail, so a yq failure
  # would yield empty input and the reverse pass would silently find no
  # stale entries. The allowlist is a precondition file, not a scanned
  # artifact, so an unparsable allowlist is a tooling error (exit 2).
  if ! allowlist_rows="$(yq eval 'to_entries[] | .key as $wf | (.value | to_entries[] | .key as $job | (.value[] | $wf + "\t" + $job + "\t" + .))' "${ALLOWLIST}")"; then
    printf '%s: could not evaluate allowlist with yq (malformed?)\n' "${ALLOWLIST}" >&2
    exit 2
  fi
  while IFS=$'\t' read -r wf job scope; do
    [[ -z ${scope} ]] && continue
    wf_path="${DIR}/${wf}"
    granted=""
    if [[ -f ${wf_path} ]]; then
      # Unchecked, a yq failure here leaves `granted` empty and the entry
      # is reported as stale — a claim about a permission block nothing
      # read. The forward pass above reports a workflow it cannot
      # evaluate as a finding against that file and moves on, so this
      # pass says the same thing rather than inventing a second verdict
      # for the same file.
      if ! granted="$(JOB="${job}" SCOPE="${scope}" yq eval \
        "[${JOBS_NODE} | explode(.) | [to_entries[] | $(eq JOB)] | reverse | .[0] | .value | .permissions | select(kind == \"map\") | [to_entries[] | $(eq SCOPE)] | reverse | .[0] | .value] | .[0] // \"\"" \
        "${wf_path}")"; then
        printf '%s: could not evaluate workflow with yq (malformed?)\n' "${wf_path}" >&2
        failed=$((failed + 1))
        continue
      fi
    fi
    if [[ ${granted} != "write" ]]; then
      printf '%s: stale entry %q/%q/%q (job does not grant that write scope)\n' \
        "${ALLOWLIST}" "${wf}" "${job}" "${scope}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${allowlist_rows}"

  # Each job's scope list must be sorted (scope names are lowercase
  # ASCII, so yq's lexical sort and C-locale sort agree). The sorted and
  # as-is lists are compared via join, because yq's == on two arrays is
  # not deep equality. Captured, not process-substituted, for the same
  # exit-status reason as above.
  if ! unsorted_rows="$(yq eval 'to_entries[] | .key as $wf | (.value | to_entries[] | select((.value | sort | join(",")) != (.value | join(","))) | $wf + "\t" + .key)' "${ALLOWLIST}")"; then
    printf '%s: could not evaluate allowlist with yq (malformed?)\n' "${ALLOWLIST}" >&2
    exit 2
  fi
  while IFS=$'\t' read -r wf job; do
    [[ -z ${job} ]] && continue
    printf '%s: scope list for %q/%q is not sorted\n' \
      "${ALLOWLIST}" "${wf}" "${job}" >&2
    failed=$((failed + 1))
  done <<<"${unsorted_rows}"
fi

shopt -u nullglob

if ((failed > 0)); then
  printf '%d permission-scope violation(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
