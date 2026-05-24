#!/usr/bin/env bash
# scripts/refresh-just-recipes.sh
#
# @description Regenerate the just-recipes managed block in
# README.md from the current `just` recipe list.
# @option --check exit 1 if README.md would change; do not mutate the working tree

# Replace the content between # BEGIN just-recipes and # END just-recipes
# in README.md with the current just recipe list from the justfile.
#
# Usage:
#   scripts/refresh-just-recipes.sh            # mutate README.md in place
#   scripts/refresh-just-recipes.sh --check    # exit 1 if the doc would change;
#                                              #   do NOT mutate the working tree

set -Eeuo pipefail
IFS=$'\n\t'
trap 'printf "[%s] %-5s line %s (exit %s): %s\n" \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" ERROR "${LINENO}" "$?" "${BASH_COMMAND}" >&2' ERR

function log() {
  printf '[%s] %-5s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >&2
}
function log_info() { log INFO "$*"; }
function log_err() { log ERROR "$*"; }

# @description Verify a required CLI tool is on PATH; exit 1 if missing.
# @arg $1 tool name
function require_tool() {
  local -r tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log_err "missing required tool: ${tool}"
    exit 1
  fi
}

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  require_tool git
  require_tool just
  require_tool awk
  require_tool cmp

  local repo_root doc
  repo_root="$(git rev-parse --show-toplevel)"
  doc="${repo_root}/README.md"
  readonly repo_root doc

  if [[ ! -f ${doc} ]]; then
    log_err "${doc} not found"
    exit 1
  fi
  if ! grep --quiet '^# BEGIN just-recipes$' "${doc}"; then
    log_err 'BEGIN marker missing from README.md'
    exit 1
  fi
  if ! grep --quiet '^# END just-recipes$' "${doc}"; then
    log_err 'END marker missing from README.md'
    exit 1
  fi

  local block_file doc_new
  block_file="$(mktemp)"
  doc_new="$(mktemp)"
  trap 'rm --force -- "${block_file:-}" "${doc_new:-}"' EXIT

  # Generate the recipe block from `just --list` output.
  # `just --list` emits recipes in alphabetical order already (with `default`
  # appearing in name order, i.e. between 'c' and 'e').  We preserve that
  # order and emit the `default` recipe first (as bare "just") to match the
  # visual convention that bare `just` introduces the recipe list.
  local raw_list
  raw_list="$(cd "${repo_root}" && just --list | tail --lines=+2)"

  # Parse all lines into name/comment pairs, stored as newline-delimited
  # "name\tcomment" in two parallel arrays (no process-substitution-local
  # scoping issues because we use a here-string, not a pipe).
  local -a pnames pcomments
  pnames=()
  pcomments=()
  while IFS= read -r line; do
    local trimmed="${line#"${line%%[! ]*}"}"
    [[ -z ${trimmed} ]] && continue
    local name comment
    name="${trimmed%% *}"
    [[ -z ${name} ]] && continue
    if [[ ${trimmed} == *'# '* ]]; then
      comment="${trimmed#*# }"
    else
      comment=''
    fi
    pnames+=("${name}")
    pcomments+=("${comment}")
  done <<<"${raw_list}"

  # Render: default first (as bare "just"), then remaining in list order.
  {
    printf '# BEGIN just-recipes\n'
    # Pass 1: emit "default" as bare "just".
    local i
    for i in "${!pnames[@]}"; do
      if [[ ${pnames[${i}]} == 'default' ]]; then
        if [[ -n ${pcomments[${i}]} ]]; then
          printf '%-20s # %s\n' 'just' "${pcomments[${i}]}"
        else
          printf 'just\n'
        fi
        break
      fi
    done
    # Pass 2: emit all non-default recipes in `just --list` order.
    for i in "${!pnames[@]}"; do
      if [[ ${pnames[${i}]} == 'default' ]]; then
        continue
      fi
      local display="just ${pnames[${i}]}"
      if [[ -n ${pcomments[${i}]} ]]; then
        printf '%-20s # %s\n' "${display}" "${pcomments[${i}]}"
      else
        printf '%s\n' "${display}"
      fi
    done
    printf '# END just-recipes\n'
  } >"${block_file}"

  # Replace inclusive of markers. awk emits the block once at BEGIN marker,
  # then suppresses every line until (and including) END.
  # Anchored to start-of-line so doc references to the marker don't falsely match.
  awk -v rep="${block_file}" '
    /^# BEGIN just-recipes$/ {
      while ((getline line < rep) > 0) print line
      close(rep)
      skip = 1
      next
    }
    /^# END just-recipes$/ {
      skip = 0
      next
    }
    !skip { print }
  ' "${doc}" >"${doc_new}"

  if [[ ${check_only} == 'true' ]]; then
    # cmp short-circuits on first byte difference and supports --silent across
    # both GNU and BSD coreutils — diff --quiet is GNU-only.
    if ! cmp --silent -- "${doc}" "${doc_new}"; then
      log_err 'just-recipes block in README.md is stale. Run scripts/refresh-just-recipes.sh and commit.'
      exit 1
    fi
    log_info 'just-recipes block in README.md is up to date'
    return 0
  fi

  mv -- "${doc_new}" "${doc}"
  log_info 'refreshed just-recipes block in README.md'
}

main "$@"
