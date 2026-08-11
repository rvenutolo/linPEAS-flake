#!/usr/bin/env bash
# scripts/check-no-opaque-procsub.sh
#
# @description Lint: no scripts/*.sh may feed a redirection from a
# process substitution whose producer's exit status is opaque to the
# consumer. A substitution runs in its own subshell, so `set -Eeuo
# pipefail` only ever sees the status of the command the redirection
# feeds — never the producer's. A failed producer hands the consumer
# empty output to score as data: either a clean pass that flags nothing
# (fail-open) or a substantive violation the input never showed (a
# tooling fault misdiagnosed as drift). Two producer shapes are banned:
#
#   1. Parser producer — `< <(yq ...)`, `< <(jq ...)`.
#   2. Function producer — `< <(f)`, `< <(f "$x")`, where `f` is a
#      function the same file defines. The ban is by producer name, not
#      by producer body, so the rule stays decidable in a single textual
#      pass and holds for whatever commands the function comes to run.
#
# `diff <(...) <(...)` stays legal: diff consumes both substitutions as
# file arguments and its own exit status is what the caller acts on, so
# no status is lost.
#
# Use the capture-into-variable idiom (or a temp file for NUL-delimited
# output) so a producer failure aborts loudly.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) for fixtures.
# Exit 0 clean, 1 on any hit, 2 on operational error.
set -Eeuo pipefail
IFS=$'\n\t'

readonly DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
[[ -d ${DIR} ]] || {
  printf 'scripts dir not found: %s\n' "${DIR}" >&2
  exit 2
}

# The bracket-escaped `(` keeps this file's own pattern-definition lines
# from matching themselves.
readonly REDIR='< <[(][[:space:]]*'
# A producer name ends at whitespace or the closing paren, so a longer
# name that merely starts with a banned one is not a hit.
readonly NAME_END='([[:space:]]|[)])'
readonly PARSER_PATTERN="${REDIR}(yq|jq)${NAME_END}"
# Doc comments are allowed to name the banned idioms (e.g. explaining why
# a script uses the capture idiom instead); only live code is a hit.
readonly COMMENT_LINE='^[0-9]+:[[:space:]]*#'

# @description Emit every function name a file defines, one per line.
# Definitions are read at column 0 only — `name() {`, `function name() {`,
# `function name {` — which is the shape every script here writes, and
# anchoring keeps the scan textual.
# @arg $1 path to a shell file
function defined_functions() {
  sed --regexp-extended --quiet \
    --expression='s/^function[[:space:]]+([^[:space:]()]+)[[:space:]]*(\(\)[[:space:]]*)?\{.*$/\1/p' \
    --expression='s/^([^[:space:]()]+)[[:space:]]*\(\)[[:space:]]*\{.*$/\1/p' \
    -- "$1"
}

# @description Emit an ERE alternation of a file's function names, each
# metacharacter escaped, or nothing when the file defines no functions.
# @arg $1 path to a shell file
function function_alternation() {
  local names
  names="$(defined_functions "$1" |
    sed --regexp-extended 's/[^A-Za-z0-9_]/\\&/g' |
    sort --unique |
    paste --serial --delimiters='|')"
  printf '%s' "${names}"
}

failed=0
shopt -s nullglob
for f in "${DIR}"/*.sh; do
  # Line numbers already reported as parser producers, so a function
  # named yq or jq — matching both patterns — is reported once.
  parser_lines=''
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    printf '%s: parser process substitution feeds a redirection (yq/jq exit status lost under pipefail): %s\n' \
      "${f}" "${hit}" >&2
    parser_lines+="${hit%%:*}"$'\n'
    failed=$((failed + 1))
  done <<<"$(grep --extended-regexp --line-number -- "${PARSER_PATTERN}" "${f}" |
    grep --invert-match --extended-regexp -- "${COMMENT_LINE}" || true)"

  alternation="$(function_alternation "${f}")"
  [[ -z ${alternation} ]] && continue
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    grep --quiet --line-regexp --fixed-strings -- "${hit%%:*}" <<<"${parser_lines}" && continue
    printf '%s: function process substitution feeds a redirection (same-file producer exit status lost under pipefail): %s\n' \
      "${f}" "${hit}" >&2
    failed=$((failed + 1))
  done <<<"$(grep --extended-regexp --line-number -- "${REDIR}(${alternation})${NAME_END}" "${f}" |
    grep --invert-match --extended-regexp -- "${COMMENT_LINE}" || true)"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d opaque process-substitution site(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
