#!/usr/bin/env bash
# scripts/check-scripts-reference-roundtrip.sh
#
# @description Lint: every piece of script-header text reaches
# docs/reference/scripts.md as written. The page is generated, and its
# freshness gate compares the committed page with a fresh render, so a
# generator that drops or rewrites header text agrees with itself and stays
# green. This check compares the other two ends instead: what each header
# says, read by an independent reader, against what the committed page shows
# once rendered the way the site renders it: python-markdown with the
# extensions mkdocs.yml loads.
#
# Scope is the generator's own: every `scripts/*.sh` not starting with an
# underscore, read header-only, and every `scripts/lib/*.sh`, whose
# function `@description` blocks are read as well. The reader splits a
# header into units at each tag. A unit's text must appear, whitespace
# collapsed and code-span backticks removed, in that script's or function's
# entry. Prose after a blank comment line that closes an `@arg`, `@option`,
# `@exitcode` or `@stdout` is a further description unit. An indented run
# whose lead-in line ends in a colon must also stay one preformatted block,
# line for line, because collapsing it keeps every word and still loses the
# shape. Three shapes of header text the generator never reads are findings
# too: prose before the first tag, a `# @tag` in a comment block between the
# header's first blank line and the first line of code, and, in a library,
# an annotation outside a function's `@description` block.
#
# Text outside a code span is Markdown on the page, so a `<placeholder>`
# reads as an HTML tag, a `<` in `<-` shows with a backslash, and a glob's
# asterisks can open emphasis. Put such text in backticks. Escaping a `<`
# cannot help: the formatter rewrites the escape into one the site's
# renderer does not honor.
#
# This wrapper enumerates the files; the checker itself is
# scripts/_scripts_reference_roundtrip.py.
#
# Env overrides (test-only):
#   SCRIPTS_DIR_OVERRIDE — alternate scripts/ root
#   SCRIPTS_REFERENCE_DOC_OVERRIDE — alternate rendered page
#   SCRIPTS_REFERENCE_MKDOCS_OVERRIDE — alternate mkdocs.yml, whose
#     markdown_extensions the page is rendered with
#
# Exit codes:
#   0  every annotation unit is published intact
#   1  header text the page drops, alters or collapses (details on stderr)
#   2  the check could not run: the page or its markers are missing,
#      python3 or python-markdown is unavailable, the scripts or lib glob
#      matches nothing (unless LINT_ALLOW_EMPTY_SCAN is set), a header is
#      not UTF-8, or no annotation text was found

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

require_tool git
require_tool python3

function main() {
  local repo_root='' scripts_dir doc mkdocs checker
  # The repo root only supplies defaults, so a run with every override set
  # works outside a work tree; without them, not finding it is a could-not-run.
  if [[ -z ${SCRIPTS_DIR_OVERRIDE:-} || -z ${SCRIPTS_REFERENCE_DOC_OVERRIDE:-} ||
    -z ${SCRIPTS_REFERENCE_MKDOCS_OVERRIDE:-} ]] &&
    ! repo_root="$(git rev-parse --show-toplevel)"; then
    log_err 'scripts-reference-roundtrip: not in a git work tree, and the overrides do not name the scripts root, page and mkdocs.yml'
    exit 2
  fi
  scripts_dir="${SCRIPTS_DIR_OVERRIDE:-${repo_root}/scripts}"
  doc="${SCRIPTS_REFERENCE_DOC_OVERRIDE:-${repo_root}/docs/reference/scripts.md}"
  mkdocs="${SCRIPTS_REFERENCE_MKDOCS_OVERRIDE:-${repo_root}/mkdocs.yml}"
  checker="${_lib_dir}/_scripts_reference_roundtrip.py"
  readonly repo_root scripts_dir doc mkdocs checker

  if [[ ! -f ${doc} ]]; then
    log_err "scripts-reference-roundtrip: ${doc} not found"
    exit 2
  fi
  if [[ ! -f ${mkdocs} ]]; then
    log_err "scripts-reference-roundtrip: ${mkdocs} not found"
    exit 2
  fi
  if [[ ! -f ${checker} ]]; then
    log_err "scripts-reference-roundtrip: ${checker} not found"
    exit 2
  fi

  local -a entries libraries args
  local f
  glob_into entries 'scripts directory' "${scripts_dir}/*.sh"
  glob_into libraries 'scripts/lib directory' "${scripts_dir}/lib/*.sh"
  args=(--entry)
  for f in "${entries[@]}"; do
    # The generator skips underscore helpers, so they have no entry.
    if [[ ${f##*/} != _* ]]; then
      args+=("${f}")
    fi
  done
  args+=(--lib "${libraries[@]}")

  # The checker reports findings as 3: Python exits 1 on its own for a
  # syntax error or an uncaught exception, and neither is a finding.
  local status=0
  python3 "${checker}" "${doc}" "${mkdocs}" "${args[@]}" || status=$?
  case "${status}" in
  0) exit 0 ;;
  3) exit 1 ;;
  2) exit 2 ;;
  *)
    log_err "scripts-reference-roundtrip: the checker died with status ${status}"
    exit 2
    ;;
  esac
}

main "$@"
