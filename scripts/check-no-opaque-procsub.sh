#!/usr/bin/env bash
# scripts/check-no-opaque-procsub.sh
#
# @description Lint: no script anywhere under `scripts/` feeds a
# redirection from a process substitution. A substitution runs in its own subshell, so `set -Eeuo
# pipefail` only ever sees the status of the command the redirection
# feeds — never the producer's. A failed producer hands the consumer
# empty output to score as data: either a clean pass that flags nothing
# (fail-open) or a substantive violation the input never showed (a
# tooling fault misdiagnosed as drift). That property holds for whatever
# the producer is, so the rule does not ask: every `< <(...)` is a hit,
# with no exemption.
#
# `diff <(...) <(...)` stays legal: diff consumes both substitutions as
# file arguments and its own exit status is what the caller acts on, so
# no status is lost.
#
# Use the capture-into-variable idiom (or a temp file for NUL-delimited
# output) so a producer failure aborts loudly.
#
# The scan recurses. A shared library under `scripts/lib/` runs inside
# whichever caller sources it, so a lost producer status there is lost
# for every script in the tree at once — the widest blast radius the
# banned shape has, and the one a top-level-only glob never reads.
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

# A redirection operator, whitespace, then a substitution. The bracket
# escapes keep this file's own pattern-definition line from matching
# itself. Whitespace is required because bash reads `<<` as a heredoc, so
# a redirection can only reach a substitution across a gap.
readonly REDIR_PATTERN='<[[:space:]]+<[(]'
# Doc comments are allowed to name the banned idiom (e.g. explaining why
# a script uses the capture idiom instead); only live code is a hit.
readonly COMMENT_LINE='^[0-9]+:[[:space:]]*#'

failed=0
shopt -s nullglob globstar
for f in "${DIR}"/**/*.sh; do
  # grep's status is read three ways rather than as a boolean: no hit in
  # this file (1) is the clean answer, but a grep that could not read the
  # file (2) scored as "no hit" would vouch for a file nothing examined.
  status=0
  hits="$(grep --extended-regexp --line-number -- "${REDIR_PATTERN}" "${f}" |
    grep --invert-match --extended-regexp -- "${COMMENT_LINE}")" || status=$?
  if ((status > 1)); then
    printf 'could not scan %s for process substitutions\n' "${f}" >&2
    exit 2
  fi
  while IFS= read -r hit; do
    [[ -z ${hit} ]] && continue
    printf '%s: process substitution feeds a redirection (producer exit status lost to its subshell): %s\n' \
      "${f}" "${hit}" >&2
    failed=$((failed + 1))
  done <<<"${hits}"
done
shopt -u nullglob globstar

if ((failed > 0)); then
  printf '%d opaque process-substitution site(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
