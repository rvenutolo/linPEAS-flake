#!/usr/bin/env bash
# scripts/refresh-just-recipes.sh
#
# @description Regenerate the just-recipes managed block in
# README.md and docs/reference/just-recipes.md from the current
# `just` recipe list.
# @option --check exit 1 if either doc would change; exit 2 if either doc
# is missing; do not mutate the working tree

# Replace the content between the BEGIN/END just-recipes markers in
# both README.md (bash-comment markers) and
# docs/reference/just-recipes.md (HTML-comment markers) with the
# current just recipe list from the justfile.
#
# Usage:
#   scripts/refresh-just-recipes.sh            # mutate both docs in place
#   scripts/refresh-just-recipes.sh --check    # exit 1 if either doc would change;
#                                              #   exit 2 if a doc is missing;
#                                              #   do NOT mutate the working tree

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"
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

  require_tool git
  require_tool just
  require_tool awk
  require_tool cmp

  local repo_root
  repo_root="$(git rev-parse --show-toplevel)"
  readonly repo_root

  # (doc, begin_marker, end_marker, wrap_with_fence) tuples — README
  # uses bash-comment markers and embeds the block inside an outer `sh`
  # code fence already, so the block content is emitted raw. The
  # standalone doc-site page uses HTML-comment markers and wraps the
  # block in its own `text` fence (with surrounding blank lines) so
  # mdformat does not rewrite the doc on every commit.
  local -a docs begin_markers end_markers wrap_fence
  docs=(
    "${repo_root}/README.md"
    "${repo_root}/docs/reference/just-recipes.md"
  )
  begin_markers=(
    '# BEGIN just-recipes'
    '<!-- BEGIN just-recipes -->'
  )
  end_markers=(
    '# END just-recipes'
    '<!-- END just-recipes -->'
  )
  wrap_fence=(
    'false'
    'true'
  )

  local block_file doc_new
  block_file="$(mktemp)"
  doc_new="$(mktemp)"
  trap 'rm --force -- "${block_file:-}" "${doc_new:-}"' EXIT

  # Generate the recipe block once — content is identical between outputs;
  # only the surrounding marker shape differs.
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

  # Render the inner recipe lines (without surrounding markers) into
  # block_file. Per-doc rendering re-emits the matching marker shape.
  {
    local i
    # Pass 1: emit "default" as bare "just".
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
  } >"${block_file}"

  local idx doc begin_marker end_marker fence rel
  for idx in "${!docs[@]}"; do
    doc="${docs[${idx}]}"
    begin_marker="${begin_markers[${idx}]}"
    end_marker="${end_markers[${idx}]}"
    fence="${wrap_fence[${idx}]}"
    rel="${doc#"${repo_root}/"}"

    # The doc is spliced, not written from scratch, so its absence is a
    # could-not-run condition rather than drift: exit 2 so the caller sends
    # the operator to the missing file instead of to a regenerate-and-commit.
    if [[ ! -f ${doc} ]]; then
      log_err "${rel} not found"
      exit 2
    fi
    if ! grep --quiet --fixed-strings --line-regexp -- "${begin_marker}" "${doc}"; then
      log_err "BEGIN marker missing from ${rel}"
      exit 1
    fi
    if ! grep --quiet --fixed-strings --line-regexp -- "${end_marker}" "${doc}"; then
      log_err "END marker missing from ${rel}"
      exit 1
    fi

    # Replace inclusive of markers. awk emits BEGIN marker, optional
    # fence wrapper, block content, optional fence, then END marker;
    # suppresses every line in between in the source. Anchored to
    # whole-line via exact match.
    awk -v rep="${block_file}" -v bm="${begin_marker}" -v em="${end_marker}" -v fence="${fence}" '
      $0 == bm {
        print bm
        if (fence == "true") { print ""; print "```text" }
        while ((getline line < rep) > 0) print line
        close(rep)
        if (fence == "true") { print "```"; print "" }
        print em
        skip = 1
        next
      }
      $0 == em {
        skip = 0
        next
      }
      !skip { print }
    ' "$(awk_path "${doc}")" >"${doc_new}"

    if [[ ${check_only} == 'true' ]]; then
      # cmp short-circuits on first byte difference and supports --silent across
      # both GNU and BSD coreutils — diff --quiet is GNU-only.
      if ! cmp --silent -- "${doc}" "${doc_new}"; then
        log_err "just-recipes block in ${rel} is stale. Run scripts/refresh-just-recipes.sh and commit."
        exit 1
      fi
      log_info "just-recipes block in ${rel} is up to date"
      continue
    fi

    if cmp --silent -- "${doc}" "${doc_new}"; then
      log_info "just-recipes block in ${rel} already up to date"
    else
      cp -- "${doc_new}" "${doc}"
      log_info "refreshed just-recipes block in ${rel}"
    fi
  done
}

main "$@"
