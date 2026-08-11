#!/usr/bin/env bash
# tests/_harness_assert_wired.test.sh
#
# Meta-harness: every harness that asserts behavior by grepping a
# captured output stream is wired to the cross-scenario discrimination
# gate in scripts/lib/harness-assert.sh.
#
# The gate only guards the harnesses that call it. A harness that greps
# scenario output without recording it is invisible to the gate, so its
# assertions may match text the nominal path also prints — green while
# verifying nothing. Wiring is a two-part act: source the library and
# call harness_assert_verify. Sourcing alone records nothing and checks
# nothing, so both parts are required.
#
# Detection is textual: a harness counts as output-asserting when it runs
# `grep` with a quiet flag (--quiet, -q, -Eq), the repo's assertion
# idiom. A harness whose greps read produced artifact content — a
# rewritten workflow, a generated doc, a list variable — rather than
# captured scenario output has no sibling scenarios to discriminate
# between and is listed in EXEMPT with its rationale.
#
# Wiring is scored on a call, not a mention: comment lines are blanked
# before matching and the verify token must open a statement, so a header
# comment describing the gate cannot stand in for being wired to it.
#
# Honors TESTS_DIR_OVERRIDE for fixtures. Exits 0 when every
# output-asserting harness is wired, 1 otherwise.

set -Eeuo pipefail
IFS=$'\n\t'
shopt -s nullglob

readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

# The repo's grep-based assertion idiom: `grep`, optional flags, then a
# quiet flag. Quiet means the harness is testing the match, not reading
# the output — an assertion rather than a data extraction.
readonly ASSERT_IDIOM='grep([[:space:]]+--?[A-Za-z][A-Za-z-]*)*[[:space:]]+(--quiet|-q|-Eq)([[:space:]]|$)'

# The two halves of the wiring, as they appear in a harness's text.
readonly GATE_LIB='scripts/lib/harness-assert.sh'
readonly GATE_VERIFY='harness_assert_verify'

# A harness counts as wired only when it CALLS the verify function, not
# when it names it. Comments are blanked before matching, and the token
# must open a statement — optionally behind a conditional operator — so a
# copied header comment cannot stand in for the call it describes.
readonly GATE_VERIFY_CALL='^[[:space:]]*(if[[:space:]]+|(\|\||&&)[[:space:]]+)*harness_assert_verify([[:space:]]|$)'

# Harness basenames excluded from the wiring verdict. Most read produced
# artifact content instead of captured scenario output, so they have no
# sibling scenarios for the gate to compare. Each entry carries the
# reason it is out of scope.
readonly -a EXEMPT=(
  'apply-patch-tag-pin-rewrite.test.sh' # asserts produced artifact content rather than captured scenario output: greps the rewritten workflow file
  'check-gh-attestation-repo.test.sh'   # asserts produced artifact content rather than captured scenario output: greps a selected-paths list variable
  'refresh-just-recipes.test.sh'        # asserts produced artifact content rather than captured scenario output: greps the generated doc
  'refresh-scripts-reference.test.sh'   # asserts produced artifact content rather than captured scenario output: greps the generated doc
  '_harness_assert_wired.test.sh'       # asserts produced artifact content rather than captured scenario output: greps harness source text, and its own detection literals self-match
  'lib-harness-assert.test.sh'          # the gate library's own spec test: it must not be gated by the library it tests, and its generated library-driving snippets are indistinguishable from live calls to any textual rule
)

# @description Emit the file with whole-line comments blanked, preserving
# line count so any reported position still matches the source. A trailing
# comment on a code line survives, which the statement-anchored call
# patterns already reject.
# @arg $1 path
function without_comments() {
  sed --regexp-extended 's/^[[:space:]]*#.*$//' -- "$1"
}

# @description Return 0 if the harness basename is on the EXEMPT list.
# @arg $1 harness basename
function is_exempt() {
  local -r name="$1"
  local e
  for e in "${EXEMPT[@]}"; do
    [[ ${name} == "${e}" ]] && return 0
  done
  return 1
}

function main() {
  local unwired=0 wired=0 f base state stripped
  for f in "${TESTS_DIR}"/*.test.sh; do
    base="$(basename -- "${f}")"
    is_exempt "${base}" && continue

    # Matching runs against the comment-blanked text held in a variable
    # rather than a pipe, so a harness larger than the pipe buffer cannot
    # lose a match to the reader closing the pipe early.
    stripped="$(without_comments "${f}")"

    grep --extended-regexp --quiet -- "${ASSERT_IDIOM}" "${f}" || continue

    local has_lib='no' has_verify='no'
    grep --fixed-strings --quiet -- "${GATE_LIB}" <<<"${stripped}" && has_lib='yes'
    grep --extended-regexp --quiet -- "${GATE_VERIFY_CALL}" <<<"${stripped}" && has_verify='yes'

    if [[ ${has_lib} == 'yes' && ${has_verify} == 'yes' ]]; then
      wired=$((wired + 1))
      continue
    fi

    if [[ ${has_lib} == 'no' && ${has_verify} == 'no' ]]; then
      state="unwired (never sources ${GATE_LIB}, never calls ${GATE_VERIFY})"
    elif [[ ${has_verify} == 'no' ]]; then
      state="half-wired (sources ${GATE_LIB} but never calls ${GATE_VERIFY})"
    else
      state="half-wired (calls ${GATE_VERIFY} but never sources ${GATE_LIB})"
    fi
    printf 'harness-assert-wired: %s asserts on captured output and is %s\n' \
      "${base}" "${state}" >&2
    unwired=$((unwired + 1))
  done

  if ((unwired > 0)); then
    printf 'harness-assert-wired: %d harness(es) grep captured output without the discrimination gate\n' \
      "${unwired}" >&2
    exit 1
  fi

  printf 'harness-assert-wired: %d output-asserting harness(es) wired to the gate\n' \
    "${wired}"
  printf '\nall tests passed\n'
  exit 0
}

main "$@"
