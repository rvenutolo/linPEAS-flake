#!/usr/bin/env bash
# scripts/refresh-ci-dag.sh
#
# @description Regenerate the ci-dag managed block in
# docs/architecture/ci-dag.md from .github/workflows/ci.yml plus the
# docs/_data/ci-check-categories.yml map.
# @option --check exit 1 if the doc would change; exit 2 if an input file
# is missing, if ci.yml has needs: references to non-existent jobs, or if
# a tool fails to read them

# Replace the content between <!-- BEGIN ci-dag --> and <!-- END ci-dag -->
# in docs/architecture/ci-dag.md with a mermaid `flowchart TD` of the
# jobs.*.needs relationships in .github/workflows/ci.yml. Nodes are
# colored by the category map in docs/_data/ci-check-categories.yml;
# jobs absent from the map render with the `aux` class.
#
# Usage:
#   scripts/refresh-ci-dag.sh           # mutate the doc in place
#   scripts/refresh-ci-dag.sh --check   # exit 1 if doc would change;
#                                       # exit 2 on a missing input file,
#                                       # dangling needs:, or a tool
#                                       # failure reading the jobs
#
# Env overrides (for tests):
#   CI_WORKFLOW_OVERRIDE      path to ci.yml
#   CATEGORIES_FILE_OVERRIDE  path to ci-check-categories.yml
#   DOC_OVERRIDE              path to ci-dag.md output

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
install_err_trap

# Category display name -> mermaid classDef key. Any job whose category
# is absent from this map (including jobs absent from the category file
# entirely, i.e. the EXEMPT auxiliary jobs) falls through to `aux`.
declare -A CAT_TO_CLASS=(
  ["Build + smoke"]="build"
  ["Security/invariant lints"]="security"
  ["Doc quality"]="doc"
  ["Conventional Commits"]="commits"
)
readonly CAT_TO_CLASS

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  # Force byte-deterministic collation for every downstream tool.
  export LC_ALL=C

  require_tool git
  require_tool yq
  require_tool jq
  require_tool awk
  require_tool cmp

  local repo_root workflow cat_map doc
  repo_root="$(git rev-parse --show-toplevel)"
  workflow="${CI_WORKFLOW_OVERRIDE:-${repo_root}/.github/workflows/ci.yml}"
  cat_map="${CATEGORIES_FILE_OVERRIDE:-${repo_root}/docs/_data/ci-check-categories.yml}"
  doc="${DOC_OVERRIDE:-${repo_root}/docs/architecture/ci-dag.md}"
  readonly repo_root workflow cat_map doc

  # An absent input is a could-not-run condition, not drift: exit 2 so the
  # caller sends the operator to the missing file rather than to a
  # regenerate-and-commit that has nothing to read.
  if [[ ! -f ${workflow} ]]; then
    log_err "${workflow} not found"
    exit 2
  fi
  if [[ ! -f ${cat_map} ]]; then
    log_err "${cat_map} not found"
    exit 2
  fi
  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 2
  fi
  if ! grep --quiet '^<!-- BEGIN ci-dag -->$' "${doc}"; then
    log_err "BEGIN marker missing from ${doc}"
    exit 1
  fi
  if ! grep --quiet '^<!-- END ci-dag -->$' "${doc}"; then
    log_err "END marker missing from ${doc}"
    exit 1
  fi

  local jobs_file cats_file block_file doc_new
  jobs_file="$(mktemp)"
  cats_file="$(mktemp)"
  block_file="$(mktemp)"
  doc_new="$(mktemp)"
  trap 'rm --force -- "${jobs_file:-}" "${cats_file:-}" "${block_file:-}" "${doc_new:-}"' EXIT

  # Extract {job: [needs...]} as JSON. Normalize `needs:` to a list:
  # GitHub Actions accepts a scalar string or a sequence; wrapping in
  # an outer array and flattening one level coerces either shape into a
  # list of strings.
  yq -o=json '
    .jobs | with_entries(.value = ([(.value.needs // [])] | flatten))
  ' "${workflow}" >"${jobs_file}"

  # Dangling-needs validation: every name in any needs[] list must be a
  # top-level job key. Exit 2 with a descriptive message if not.
  local dangling
  dangling="$(jq --raw-output '
    . as $m
    | ([keys[]]) as $jobs
    | ([.[] | .[]]) as $needs
    | ($needs - $jobs)
    | unique
    | .[]
  ' "${jobs_file}")"
  if [[ -n ${dangling} ]]; then
    log_err "${workflow} has needs: references to non-existent jobs:"
    while IFS= read -r n; do log_err "  ${n}"; done <<<"${dangling}"
    exit 2
  fi

  # Capture jq's output (and exit status) into a variable rather than
  # feeding the loop from `< <(jq ... | sort)`: a process substitution's
  # exit status is not propagated under set -Eeuo pipefail, and a
  # trailing pipe masks it further, so a jq failure would yield empty
  # loop input and render a silently truncated graph.
  local job_keys
  if ! job_keys="$(jq --raw-output 'keys[]' "${jobs_file}")"; then
    log_err "${workflow}: could not read job keys with jq (malformed job map?)"
    exit 2
  fi
  job_keys="$(sort <<<"${job_keys}")"

  # Build the category lookup file: lines of "<job><TAB><classKey>",
  # sorted by job. Jobs absent from the map (or whose category isn't in
  # CAT_TO_CLASS) fall through to "aux". A workflow with no jobs at all
  # yields an empty capture; the guard keeps that from entering the loop
  # as one empty-string iteration.
  {
    local job cat cls
    if [[ -n ${job_keys} ]]; then
      while IFS= read -r job; do
        [[ -z ${job} ]] && continue
        cat="$(yq ".\"${job}\" // \"\"" "${cat_map}")"
        if [[ -z ${cat} || ${cat} == 'null' ]]; then
          cls='aux'
        else
          cls="${CAT_TO_CLASS[${cat}]:-aux}"
        fi
        printf '%s\t%s\n' "${job}" "${cls}"
      done <<<"${job_keys}"
    fi
  } >"${cats_file}"

  # Render the block.
  {
    printf '<!-- BEGIN ci-dag -->\n'
    printf '\n'
    printf '```mermaid\n'
    printf 'flowchart TD\n'
    printf '  classDef build fill:#c8e6c9,stroke:#2e7d32\n'
    printf '  classDef security fill:#ffe0b2,stroke:#e65100\n'
    printf '  classDef doc fill:#bbdefb,stroke:#1565c0\n'
    printf '  classDef commits fill:#e1bee7,stroke:#6a1b9a\n'
    printf '  classDef aux fill:#eeeeee,stroke:#616161\n'
    printf '\n'
    # Node declarations: one per job, alphabetical by job.
    awk -F'\t' '{ printf "  %s:::%s\n", $1, $2 }' "${cats_file}"
    # Edges: "<need> --> <job>", sorted by (job, need).
    local edges
    edges="$(jq --raw-output '
      to_entries[]
      | . as $e
      | $e.value[]
      | "\(.)\t\($e.key)"
    ' "${jobs_file}" | sort --field-separator=$'\t' --key=2,2 --key=1,1)"
    if [[ -n ${edges} ]]; then
      printf '\n'
      printf '%s\n' "${edges}" | awk -F'\t' '{ printf "  %s --> %s\n", $1, $2 }'
    fi
    printf '```\n'
    printf '\n'
    printf '<!-- END ci-dag -->\n'
  } >"${block_file}"

  # Replace inclusive of markers.
  awk -v rep="${block_file}" '
    /^<!-- BEGIN ci-dag -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END ci-dag -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "${doc}" >"${doc_new}"

  if [[ ${check_only} == 'true' ]]; then
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err "ci-dag block in ${doc} is stale. Run scripts/refresh-ci-dag.sh and commit."
      exit 1
    fi
    log_info "ci-dag block in ${doc} is up to date"
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  log_info "refreshed ci-dag block in ${doc}"
}

main "$@"
