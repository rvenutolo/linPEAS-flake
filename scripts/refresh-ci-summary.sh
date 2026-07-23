#!/usr/bin/env bash
# scripts/refresh-ci-summary.sh
#
# @description Regenerate the ci-summary managed block in README.md
# from required-checks.md plus the ci-check-categories.yml map.
# @option --check exit 1 if README.md would change; do not mutate the working tree

# Replace the content between <!-- BEGIN ci-summary --> and <!-- END ci-summary -->
# in README.md with a categorized bullet list generated from two sources:
#   - docs/security/required-checks.md  (required context names, source of truth)
#   - docs/_data/ci-check-categories.yml  (context -> category map)
#
# The generator FAILS if the two sources diverge in either direction.
#
# Usage:
#   scripts/refresh-ci-summary.sh            # mutate README.md in place
#   scripts/refresh-ci-summary.sh --check    # exit 1 if the doc would change;
#                                            #   do NOT mutate the working tree

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
install_err_trap

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  # Force byte-deterministic collation for every downstream tool (sort, comm,
  # awk equality). Without this, dev locales like en_US.UTF-8 reorder context
  # names differently than C-locale CI runners, producing churn in the rendered
  # block and failing --check across environments.
  export LC_ALL=C

  require_tool git
  require_tool yq
  require_tool awk
  require_tool cmp

  local repo_root doc cat_map required_checks_doc
  repo_root="$(git rev-parse --show-toplevel)"
  doc="${repo_root}/README.md"
  cat_map="${repo_root}/docs/_data/ci-check-categories.yml"
  required_checks_doc="${repo_root}/docs/security/required-checks.md"
  readonly repo_root doc cat_map required_checks_doc

  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 1
  fi
  if [[ ! -f ${cat_map} ]]; then
    log_err "${cat_map} not found"
    exit 1
  fi
  if [[ ! -f ${required_checks_doc} ]]; then
    log_err "${required_checks_doc} not found"
    exit 1
  fi
  if ! grep --quiet '^<!-- BEGIN ci-summary -->$' "${doc}"; then
    log_err 'BEGIN marker missing from README.md'
    exit 1
  fi
  if ! grep --quiet '^<!-- END ci-summary -->$' "${doc}"; then
    log_err 'END marker missing from README.md'
    exit 1
  fi

  local contexts_file map_keys_file block_file doc_new
  contexts_file="$(mktemp)"
  map_keys_file="$(mktemp)"
  block_file="$(mktemp)"
  doc_new="$(mktemp)"
  trap 'rm --force -- "${contexts_file:-}" "${map_keys_file:-}" "${block_file:-}" "${doc_new:-}"' EXIT

  # Extract required context names from the table (first column, skip header and separator rows).
  # Separator rows are pure-dash cells (e.g. "| --- |"); we exclude them by
  # requiring at least one alphanumeric or non-dash character in the cell value.
  awk -F'|' '/^\| *[a-z0-9][a-z0-9-]* *\| / {
    ctx = $2
    gsub(/ /, "", ctx)
    print ctx
  }' "${required_checks_doc}" |
    sort --unique >"${contexts_file}"

  # Extract keys from the category map.
  yq 'keys | .[]' "${cat_map}" | sort --unique >"${map_keys_file}"

  # DIVERGENCE CHECK direction 1: required contexts not in the map.
  local missing_from_map
  missing_from_map="$(comm -23 "${contexts_file}" "${map_keys_file}")"
  if [[ -n ${missing_from_map} ]]; then
    log_err "Required contexts missing from ${cat_map}:"
    while IFS= read -r ctx; do
      log_err "  ${ctx}"
    done <<<"${missing_from_map}"
    exit 1
  fi

  # DIVERGENCE CHECK direction 2: map keys not in required contexts.
  local extra_in_map
  extra_in_map="$(comm -13 "${contexts_file}" "${map_keys_file}")"
  if [[ -n ${extra_in_map} ]]; then
    log_err "Category-map entries not in ${required_checks_doc}:"
    while IFS= read -r ctx; do
      log_err "  ${ctx}"
    done <<<"${extra_in_map}"
    exit 1
  fi

  # Build the block: for each category (alphabetical), one bullet listing all
  # contexts in that category (alphabetical within category), as inline code spans.
  {
    printf '<!-- BEGIN ci-summary -->\n'
    printf '\n'
    # Emit "category TAB context" pairs sorted by category then context,
    # then group by category to render each bullet.
    local pairs_file
    pairs_file="$(mktemp)"
    # Append pairs_file to the outer trap so it's cleaned up too.
    trap 'rm --force -- "${contexts_file:-}" "${map_keys_file:-}" "${block_file:-}" "${doc_new:-}" "${pairs_file:-}"' EXIT
    yq 'to_entries | .[] | .value + "\t" + .key' "${cat_map}" | sort >"${pairs_file}"
    awk -F'\t' '
      {
        cat = $1
        ctx = $2
        if (cat != prev_cat) {
          if (prev_cat != "") {
            printf ".\n"
          }
          printf "- **%s**: `%s`", cat, ctx
          prev_cat = cat
        } else {
          printf ", `%s`", ctx
        }
      }
      END {
        if (prev_cat != "") printf ".\n"
      }
    ' "${pairs_file}"
    printf '\n'
    printf '<!-- END ci-summary -->\n'
  } >"${block_file}"

  # Replace inclusive of markers. awk emits the block once at BEGIN marker,
  # then suppresses every line until (and including) END.
  # Anchored to start-of-line so doc references to the marker don't falsely match.
  awk -v rep="${block_file}" '
    /^<!-- BEGIN ci-summary -->$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^<!-- END ci-summary -->$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "${doc}" >"${doc_new}"

  if [[ ${check_only} == 'true' ]]; then
    # cmp short-circuits on first byte difference and supports --silent across
    # both GNU and BSD coreutils — diff --quiet is GNU-only.
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err 'CI summary block in README.md is stale. Run scripts/refresh-ci-summary.sh and commit.'
      exit 1
    fi
    log_info 'CI summary block in README.md is up to date'
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  log_info 'refreshed CI summary block in README.md'
}

main "$@"
