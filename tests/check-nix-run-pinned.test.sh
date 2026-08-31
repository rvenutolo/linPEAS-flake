#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-nix-run-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/nix-run-pinned"

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
  elif [[ -n ${want_msg} ]] && ! grep --fixed-strings --quiet -- "${want_msg}" "${err_file}"; then
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

# All four clean shapes in one invocation: each on its own exits 0 with
# no output, which is one indistinguishable outcome repeated four times
# rather than four separate observations — the discrimination gate flags
# every such pair as sharing one output. One invocation over all four
# still exercises every clean shape; it stops pretending four silent
# passes are four different things to have proven.
run_expect 'all-good-shapes' \
  "${FIXTURES}/good-shell.sh"$'\n'"${FIXTURES}/good-pinned-rev.sh"$'\n'"${FIXTURES}/good-local-flake.sh"$'\n'"${FIXTURES}/good-prose.md"$'\n'"${FIXTURES}/good-composite-action.yml" \
  0 ""

# The three fixtures below carry the identical violating line (`nix run
# nixpkgs#cosign -- sign foo`), so their messages differ only in which
# file each names — assert that instead of the shared word "unpinned",
# which every bad-* fixture's message also contains.
expect bad-unpinned.sh 1 "bad-unpinned.sh: unpinned bare"
expect bad-fence.md 1 "bad-fence.md: unpinned bare"
expect bad-fence-unlabeled.md 1 "bad-fence-unlabeled.md: unpinned bare"
expect bad-run-flag.sh 1 "nix run --quiet nixpkgs#cosign -- version"
expect bad-shell-unpinned.sh 1 "nix shell nixpkgs#cosign --command cosign version"
expect bad-develop-unpinned.sh 1 "nix develop nixpkgs#foo"
expect bad-build-unpinned.sh 1 "nix build nixpkgs#bar"
expect bad-trailing-ref.sh 1 "nix shell .#jq nixpkgs#cosign --command cosign version"
expect bad-composite-action.yml 1 "nix shell nixpkgs#yq-go --command yq --version"

# @description Drive the enumeration itself, not a fixture: with
# PATHS_OVERRIDE unset the script enumerates via `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output. A status
# check cannot see that, so the empty scan set has to be the assertion.
# @arg $1 expected exit code  @arg $2 expected stderr substring
function expect_empty_scan() {
  local -r want_exit="$1" want_msg="$2"
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
  harness_assert_record 'empty-scan' "${want_msg}" "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != "${want_exit}" ]]; then
    fail "$(printf 'empty-scan: exit %s, want %s' "${got_exit}" "${want_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${want_msg}" "${err_file}"; then
    fail "$(printf 'empty-scan: stderr missing %q' "${want_msg}")"
    cat -- "${err_file}" >&2
  else
    pass 'empty-scan'
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_empty_scan 2 "enumerated 0 files via git ls-files"

# @description A workflow filename with an embedded newline, holding an
# unpinned `nix run nixpkgs#jq`, defeats a line-oriented handoff: `git
# ls-files` (without `-z`) C-quotes such a name onto one newline-escaped
# line, so a `while read` loop reads it as one bogus path that then fails
# the `[[ -f ]]` gate — the violation is enumerated right out of the
# scan. Built in a throwaway repo under the harness temp directory rather
# than a committed fixture: a committed newline filename would itself be
# rejected by check-path-hygiene.sh and is hostile to `git checkout`.
function expect_newline_workflow_name() {
  local -r name='newline-workflow-name'
  local repo_dir evil_name got_exit=0
  local out_file err_file outcome_file
  repo_dir="$(mktemp --directory)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  mkdir --parents "${repo_dir}/.github/workflows"
  printf 'name: clean\njobs:\n  a:\n    steps:\n      - run: echo ok\n' \
    >"${repo_dir}/.github/workflows/clean.yml"
  evil_name="$(printf 'ev\nil').yml"
  printf 'name: evil\njobs:\n  a:\n    steps:\n      - run: nix run nixpkgs#jq\n' \
    >"${repo_dir}/.github/workflows/${evil_name}"
  git -C "${repo_dir}" init --quiet
  git -C "${repo_dir}" config user.email t@t.t
  git -C "${repo_dir}" config user.name t
  git -C "${repo_dir}" add --all

  (cd "${repo_dir}" && "${SCRIPT}") >"${out_file}" 2>"${err_file}" || got_exit=$?
  rm --recursive --force -- "${repo_dir}"
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'nixpkgs#jq' "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'nixpkgs#jq' "${err_file}"; then
    fail "$(printf '%s: stderr missing violation for the newline-named workflow' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_newline_workflow_name

# @description `awk` reads a file operand whose text is `name=value` as a
# variable assignment rather than a filename: fed a relative path whose
# first component contains `=`, it finds no file operand, reads stdin
# (empty here), and exits 0 having scanned nothing — so a violating file
# at such a path would score as clean. Built in a throwaway directory
# under the harness temp directory, `cd`'d into so PATHS_OVERRIDE can
# carry the hazard shape as a genuinely relative path, rather than a
# committed fixture: a directory segment named with `=` is legal on
# disk but an unusual thing to commit for a single scenario.
function expect_relative_override_with_equals() {
  local -r name='relative-override-with-equals'
  local work got_exit=0
  local out_file err_file outcome_file
  work="$(mktemp --directory)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  mkdir --parents "${work}/a=b"
  printf 'run: nix run nixpkgs#ripgrep -- --version\n' >"${work}/a=b/bad.sh"

  (cd "${work}" && PATHS_OVERRIDE="a=b/bad.sh" "${SCRIPT}") \
    >"${out_file}" 2>"${err_file}" || got_exit=$?
  rm --recursive --force -- "${work}"
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'a=b/bad.sh' "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'a=b/bad.sh' "${err_file}"; then
    fail "$(printf '%s: stderr missing violation for the equals-first-component path' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_relative_override_with_equals

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
