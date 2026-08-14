#!/usr/bin/env bash
# tests/check-enumerate-helper-required.test.sh
#
# Failure-mode harness for scripts/check-enumerate-helper-required.sh.
#
# Each scenario drives the lint through PATHS_OVERRIDE so a fixture is a
# plain file rather than a directory tree, and asserts the diagnostic
# that names the rule branch under test.

set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-enumerate-helper-required.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/enumerate-helper-required"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() {
  printf 'PASS: %s\n' "$1"
}

# @description Run the lint under a given PATHS_OVERRIDE, record the
# outcome with the cross-scenario discrimination gate, and assert exit
# code plus an expected output substring.
# @arg $1 scenario name  @arg $2 PATHS_OVERRIDE value
# @arg $3 expected exit code  @arg $4 expected substring ('' none)
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
    cat -- "${out_file}" "${err_file}" >&2
  elif [[ -n ${want_msg} ]] && ! grep --fixed-strings --quiet -- "${want_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing %q' "${name}" "${want_msg}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

# @description Run against one named fixture; its basename doubles as
# the scenario name.
# @arg $1 fixture basename  @arg $2 expected exit
# @arg $3 expected substring ('' none)
function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  run_expect "${fixture}" "${FIXTURES}/${fixture}" "${want_exit}" "${want_msg}"
}

# The three violating shapes. Each asserts its own file, line and column,
# which is what tells them apart — the trailing sentence of the
# out-of-helper diagnostic is shared by construction.
expect bad-bare-find.sh 1 'bad-bare-find.sh:8:1: find runs outside enumerate_into'
expect bad-bare-git-ls-files.sh 1 'bad-bare-git-ls-files.sh:7:12: git ls-files runs outside enumerate_into'
# An empty rationale is its own finding rather than a silent exemption:
# honoring it would make the marker a way to opt out of stating a reason.
expect bad-empty-rationale.sh 1 \
  'bad-empty-rationale.sh:9:12: enumerate-exempt marker carries no rationale'

# All four clean shapes in one invocation. Each alone prints an
# indistinguishable clean summary, so four scenarios would be four names
# over one observation; the merged summary's counts are what prove all
# four were read — three producer calls (direct, wrapper, exempt) across
# four files, one of them exempted.
#
# Those counts are load-bearing rather than decorative. Mutating the lint
# to stop recognizing a producer handed straight to the helper leaves
# this run at exit 0 and moves only the tally, 3 to 2 — so a scenario
# asserting the exit code, or merely that the run came back clean, would
# score a lint that had gone half-blind as a pass.
run_expect 'all-good-shapes' \
  "${FIXTURES}/good-direct.sh"$'\n'"${FIXTURES}/good-wrapper.sh"$'\n'"${FIXTURES}/good-exempt.sh"$'\n'"${FIXTURES}/good-mentions-only.sh" \
  0 '4 file(s) scanned, 3 scan site(s) classified, 1 exemption(s)'

# The glob rule's violating shapes. A loop that expands its own pattern
# at the loop head has nowhere to state how many files it matched, so an
# empty root produces the clean run a populated one would.
expect bad-bare-glob-loop.sh 1 \
  'bad-bare-glob-loop.sh:10:1: this for loop iterates a glob directly'
expect bad-glob-empty-rationale.sh 1 \
  'bad-glob-empty-rationale.sh:9:1: glob-exempt marker carries no rationale'

# Each rule owns its own marker word, and these two prove the keying in
# both directions: an exemption written for one class must not silence
# the other, or a single marker word would be an opt-out from both rules
# at once no matter which one the site was actually reasoned about.
expect bad-glob-marker-mismatch.sh 1 \
  'bad-glob-marker-mismatch.sh:11:1: this for loop iterates a glob directly'
expect bad-producer-marker-mismatch.sh 1 \
  'bad-producer-marker-mismatch.sh:10:12: git ls-files runs outside enumerate_into'

# The glob rule's clean shapes, merged for the same reason the producer
# rule's are: each alone prints an indistinguishable clean summary, and
# the counts are what prove all four were read — a helper call, an
# exempted loop, two helper calls whose only glob is a call argument, and
# a loop over an array that carries no pattern at all.
#
# The tally is load-bearing here too. A rule that stopped counting the
# helper's own call sites would leave this run at exit 0 and move only
# the count, so a scenario asserting the exit code alone would score a
# half-blind rule as a pass.
run_expect 'all-good-glob-shapes' \
  "${FIXTURES}/good-glob-into.sh"$'\n'"${FIXTURES}/good-glob-exempt.sh"$'\n'"${FIXTURES}/good-glob-arg-only.sh"$'\n'"${FIXTURES}/good-no-glob-loop.sh" \
  0 '4 file(s) scanned, 4 scan site(s) classified, 1 exemption(s)'

# @description The producer tally is its own breadth assertion, separate
# from the file enumeration: a real file can be scanned and yield no
# producer at all. That has to be a could-not-run rather than the clean
# summary a genuinely enumeration-free tree prints, because a grammar
# that stopped recognizing producers would report exactly the same line.
run_expect 'zero-producer-scan' "${FIXTURES}/good-mentions-only.sh" 2 \
  'classified 0 scan site(s) across 1 file(s) scanned'

# @description Same input, opted out: proves the documented release
# valve turns that run green rather than only existing in prose.
function expect_zero_producer_allowed() {
  local -r name='zero-producer-scan-allowed'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  LINT_ALLOW_EMPTY_SCAN=1 PATHS_OVERRIDE="${FIXTURES}/good-mentions-only.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" '1 file(s) scanned, 0 scan site(s) classified, 0 exemption(s)' \
    "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 0 ]]; then
    fail "$(printf '%s: exit %s, want 0' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- '1 file(s) scanned, 0 scan site(s) classified, 0 exemption(s)' "${out_file}"; then
    fail "$(printf '%s: stdout missing the clean summary' "${name}")"
    cat -- "${out_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_zero_producer_allowed

# @description A path named in the scan set that is not there is
# operator input pointing at nothing, which is a could-not-run rather
# than a file to drop quietly from the set.
run_expect 'absent-named-path' "${FIXTURES}/no-such-fixture.sh" 2 \
  'named in the scan set but not found'

# @description Drive the enumeration itself rather than a fixture: with
# PATHS_OVERRIDE unset the lint enumerates through `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output — the
# should-be could-not-run that collapses into a clean-looking empty scan
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

# @description A file that is not valid shell defeats `shfmt --to-json`
# outright: with no syntax tree to walk, the lint must report a
# could-not-run rather than read the empty result as a clean file. Built
# at runtime rather than committed, because a tracked file that fails to
# parse as shell would fail this repo's own shellcheck and shfmt hooks on
# every future commit.
function expect_unparsable_shell() {
  local -r name='unparsable-shell'
  local bad_file out_file err_file outcome_file got_exit=0
  bad_file="$(mktemp --suffix=.sh)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  printf '%s\n' '#!/usr/bin/env bash' 'find . -name "unterminated' >"${bad_file}"
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
