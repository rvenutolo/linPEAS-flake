#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-awk-operand-explicit.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/awk-operand-explicit"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() {
  printf 'PASS: %s\n' "$1"
}

# @description Run the script under a given PATHS_OVERRIDE, record the
# outcome with the cross-scenario discrimination gate, and assert exit
# code plus an optional stderr substring.
# @arg $1 scenario name
# @arg $2 PATHS_OVERRIDE value
# @arg $3 expected exit code  @arg $4 expected stderr substring ('' none)
function run_expect() {
  local -r name="$1" paths_override="$2" want_exit="$3" want_msg="$4"
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${paths_override}" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != "${want_exit}" ]]; then
    fail "$(printf '%s: exit %s, want %s' "${name}" "${got_exit}" "${want_exit}")"
    cat -- "${err_file}" >&2
  elif [[ -n ${want_msg} ]] && ! grep --fixed-strings --quiet -- "${want_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: stderr missing %q' "${name}" "${want_msg}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

# @description Run the script against one named fixture file under
# FIXTURES; the fixture's basename doubles as the scenario name.
# @arg $1 fixture basename  @arg $2 expected exit code
# @arg $3 expected stderr substring ('' none)
function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  run_expect "${fixture}" "${FIXTURES}/${fixture}" "${want_exit}" "${want_msg}"
}

# All five clean shapes (wrapped operand, stdin redirect, here-string,
# pipeline input, and a wrapped operand alongside a --file program-file
# flag) in one invocation: each on its own exits 0 with an
# indistinguishable "0 violations" summary, so five separate scenarios
# would be five names over one observation. One invocation still
# exercises every clean shape; the summary's scanned/checked counts (5
# files, 2 operands: good-wrapped.sh and good-program-file.sh each carry
# one) prove all five were actually read.
run_expect 'all-good-shapes' \
  "${FIXTURES}/good-wrapped.sh"$'\n'"${FIXTURES}/good-stdin.sh"$'\n'"${FIXTURES}/good-herestring.sh"$'\n'"${FIXTURES}/good-piped.sh"$'\n'"${FIXTURES}/good-program-file.sh" \
  0 '5 file(s) scanned, 2 operand(s) checked, 0 violations'

# Each bad fixture names its own file and line/column in the
# diagnostic, which is what discriminates these three from each other
# and from the merged good-shapes pass above.
expect bad-bare-operand.sh 1 'bad-bare-operand.sh:6:9: awk file operand not spelled'
expect bad-multiline-program.sh 1 'bad-multiline-program.sh:10:3: awk file operand not spelled'
# The second operand's own column (30) is asserted, not just the file
# and violation count: bad-second-operand.sh's first operand is
# correctly wrapped, so a lint that flagged the wrapped one too (or
# instead) would still print one violation for this file and pass an
# assertion that only checked the file name and the "1 violation" tally.
expect bad-second-operand.sh 1 'bad-second-operand.sh:9:30: awk file operand not spelled'

# These four exercise the classifier shapes an earlier version of
# flag_class misjudged: an attached -f/--file value (a word that is
# not an *exact* flag-name match still has to be told apart from one
# that merely starts with a flag name — a jq `.` rebinding bug made
# every such word classify as -v and get silently absorbed), --source
# (which supplies the program text and so must mark it supplied, or
# the real operand after it gets read as the program instead), and a
# legally repeated -f (which must still recognize the second -f as a
# flag rather than stop recognizing flags once any program is
# supplied — the fix for the first three shapes would otherwise turn
# a legal two-program-file call into two false positives).
expect bad-attached-f-flag.sh 1 'bad-attached-f-flag.sh:6:16: awk file operand not spelled'
expect bad-attached-file-flag.sh 1 'bad-attached-file-flag.sh:6:21: awk file operand not spelled'
expect bad-source-flag.sh 1 'bad-source-flag.sh:6:32: awk file operand not spelled'

# @description bad-repeated-f-flag.sh must yield exactly one violation
# (the trailing bare operand), not the three the pre-fix classifier
# reported for a legally-repeated -f (two of them false positives, on
# -f itself and on b.awk). The registered assertion is the
# file:line:col diagnostic, which discriminates this scenario from
# every sibling bad-* fixture; the violation *count* is checked
# separately (by counting matching diagnostic lines rather than
# registering the shared "N awk file operand(s)..." tally text, which
# every single-violation bad-* fixture also emits and so cannot
# discriminate) because the count is what a regression back to
# over-flagging would actually break — a check that only looked for
# "a violation exists" would not catch it.
function expect_bad_repeated_f_flag() {
  local -r name='bad-repeated-f-flag.sh'
  local out_file err_file outcome_file got_exit=0 diag_count
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${FIXTURES}/bad-repeated-f-flag.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'bad-repeated-f-flag.sh:6:23: awk file operand not spelled' \
    "${outcome_file}" "${out_file}" "${err_file}"

  diag_count="$(grep --fixed-strings --count -- ': awk file operand not spelled' "${err_file}")"
  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif [[ ${diag_count} != 1 ]]; then
    fail "$(printf '%s: %s violation diagnostic line(s), want exactly 1' "${name}" "${diag_count}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'bad-repeated-f-flag.sh:6:23: awk file operand not spelled' "${err_file}"; then
    fail "$(printf '%s: stderr missing the trailing-operand diagnostic' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_bad_repeated_f_flag

# @description Drive the enumeration itself, not a fixture: with
# PATHS_OVERRIDE unset the script enumerates via `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output — a
# should-be could-not-run collapsing to a clean-looking empty scan
# unless `enumerate_into` catches it.
function expect_empty_scan() {
  local -r name='empty-scan'
  local out_file err_file outcome_file got_exit=0 index_dir
  index_dir="$(mktemp --directory)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  (cd "${REPO_ROOT}" &&
    GIT_INDEX_FILE="${index_dir}/absent.idx" "${SCRIPT}") \
    >"${out_file}" 2>"${err_file}" || got_exit=$?
  rm --recursive --force -- "${index_dir}"
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'enumerated 0 files via git ls-files' \
    "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 2 ]]; then
    fail "$(printf '%s: exit %s, want 2' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'enumerated 0 files via git ls-files' "${err_file}"; then
    fail "$(printf '%s: stderr missing the empty-scan diagnostic' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_empty_scan

# @description A file that is not valid shell at all defeats
# `shfmt --to-json` outright: the lint has no syntax tree to walk, so
# it must report a could-not-run rather than reading the empty/partial
# result as a clean file. Built as a throwaway temp file rather than a
# tracked fixture: a committed file that fails to parse as shell would
# itself fail this repo's shellcheck/shfmt hooks on every future commit.
function expect_unparsable_shell() {
  local -r name='unparsable-shell'
  local bad_file out_file err_file outcome_file got_exit=0
  bad_file="$(mktemp --suffix=.sh)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  printf '%s\n' '#!/usr/bin/env bash' "awk 'unterminated" >"${bad_file}"
  PATHS_OVERRIDE="${bad_file}" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  rm --force -- "${bad_file}"
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'shfmt could not parse this file as shell for AST inspection' \
    "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 2 ]]; then
    fail "$(printf '%s: exit %s, want 2' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'shfmt could not parse this file as shell for AST inspection' "${err_file}"; then
    fail "$(printf '%s: stderr missing the parse-failure diagnostic' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_unparsable_shell

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
