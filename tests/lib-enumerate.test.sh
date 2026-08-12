#!/usr/bin/env bash
# tests/lib-enumerate.test.sh — proves scripts/lib/enumerate.sh turns a
# NUL-delimited producer into an array with no line-oriented data loss,
# that producer failure and an empty scan set are both surfaced as exit 2
# rather than silently accepted as an empty result, and that a final
# record missing its trailing NUL is kept rather than dropped.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/enumerate.sh"

failures=0
rc=0
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run a library-driving snippet as its own bash process, so
# that `enumerate_into`'s `exit` terminates only that process rather than
# this harness, capture its streams, and record the outcome with the
# cross-scenario discrimination gate. Sets `rc` (a plain, non-local
# variable of the calling scope) rather than returning through a `$()`
# command substitution: a substitution forks a subshell, and
# `harness_assert_record`'s pool state lives in globals that a subshell's
# exit would discard, leaving the parent with no recorded scenarios.
# @arg $1 scenario name  @arg $2 asserted substring ('' if none)
# @arg $3 snippet body: defines a stub producer, calls `enumerate_into`,
#   and on success prints `size=<n>` followed by `declare -p out` so the
#   array's contents (including any embedded newline) are captured on one
#   unambiguous line.
function run_scenario() {
  local -r name="$1" substring="$2" body="$3"
  local -r script="${work}/${name}.sh"
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  rc=0
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf "IFS=\$'\\\\n\\\\t'\n"
    printf 'unset LINT_ALLOW_EMPTY_SCAN\n'
    printf 'source %q\n' "${LIB}"
    printf '%s\n' "${body}"
  } >"${script}"
  bash "${script}" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# 1. ok-multiple — three NUL-delimited names fill a three-element array.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'ok-multiple' 'size=3' '
function stub_emit_three() { printf "%s\0" alpha beta gamma; }
declare -a out=()
enumerate_into out "stub_emit_three" stub_emit_three
printf "size=%d\n" "${#out[@]}"
declare -p out
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'size=3' "${work}/ok-multiple.out" &&
  grep --fixed-strings --quiet -- '[0]="alpha" [1]="beta" [2]="gamma"' "${work}/ok-multiple.out"; then
  pass 'ok-multiple: three records fill a three-element array, exit 0'
else
  fail "ok-multiple: expected exit 0 + three-element array, got exit ${rc}"
  cat -- "${work}/ok-multiple.out" "${work}/ok-multiple.err" >&2
fi

# 2. ok-newline-name — a name containing a newline survives as one element.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'ok-newline-name' 'size=1' '
function stub_emit_newline() { printf "line-one\nline-two\0"; }
declare -a out=()
enumerate_into out "stub_emit_newline" stub_emit_newline
printf "size=%d\n" "${#out[@]}"
declare -p out
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'size=1' "${work}/ok-newline-name.out" &&
  grep --fixed-strings --quiet -- $'line-one\nline-two' "${work}/ok-newline-name.out"; then
  pass 'ok-newline-name: an embedded newline stays inside one element, exit 0'
else
  fail "ok-newline-name: expected one element carrying the newline, got exit ${rc}"
  cat -- "${work}/ok-newline-name.out" "${work}/ok-newline-name.err" >&2
fi

# 3. producer-fails — a non-zero producer exit is exit 2, naming the
# caller-supplied label.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'producer-fails' 'stub producer label failed enumerating the scan set' '
# Body in parens: a function defined with `()` runs its body in a
# subshell, so this `exit` ends only the producer, not the harness
# process calling it via `"$@"` — a plain `{ }` body would `exit` the
# whole enumerate_into caller instead of merely failing the producer.
function stub_producer_fail() ( printf "partial\0"; exit 1 )
declare -a out=()
enumerate_into out "stub producer label" stub_producer_fail
printf "size=%d\n" "${#out[@]}"
'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'stub producer label failed enumerating the scan set' \
    "${work}/producer-fails.err"; then
  pass 'producer-fails: a failing producer is exit 2, stderr names the caller label'
else
  fail "producer-fails: expected exit 2 + caller label in stderr, got exit ${rc}"
  cat -- "${work}/producer-fails.out" "${work}/producer-fails.err" >&2
fi

# 4. empty-scan — a producer exiting 0 with no output is exit 2, hinting
# at the escape hatch.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'empty-scan' 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate' '
function stub_empty() { :; }
declare -a out=()
enumerate_into out "stub_empty" stub_empty
printf "size=%d\n" "${#out[@]}"
'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate' \
    "${work}/empty-scan.err"; then
  pass 'empty-scan: an empty scan set is exit 2, stderr carries the hint'
else
  fail "empty-scan: expected exit 2 + LINT_ALLOW_EMPTY_SCAN hint, got exit ${rc}"
  cat -- "${work}/empty-scan.out" "${work}/empty-scan.err" >&2
fi

# 5. empty-scan-allowed — same producer, opted out via
# LINT_ALLOW_EMPTY_SCAN, is exit 0 with an empty array.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'empty-scan-allowed' 'size=0' '
function stub_empty() { :; }
export LINT_ALLOW_EMPTY_SCAN=1
declare -a out=()
enumerate_into out "stub_empty" stub_empty
printf "size=%d\n" "${#out[@]}"
declare -p out
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'size=0' "${work}/empty-scan-allowed.out"; then
  pass 'empty-scan-allowed: LINT_ALLOW_EMPTY_SCAN=1 turns the same producer exit 0'
else
  fail "empty-scan-allowed: expected exit 0 + empty array, got exit ${rc}"
  cat -- "${work}/empty-scan-allowed.out" "${work}/empty-scan-allowed.err" >&2
fi

# 6. trailing-nul — an output ending on a NUL (record boundary followed
# by an empty record) yields no phantom empty element.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'trailing-nul' 'size=2' '
function stub_trailing_nul() { printf "%s\0%s\0\0" one two; }
declare -a out=()
enumerate_into out "stub_trailing_nul" stub_trailing_nul
printf "size=%d\n" "${#out[@]}"
declare -p out
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'size=2' "${work}/trailing-nul.out" &&
  grep --fixed-strings --quiet -- '[0]="one" [1]="two"' "${work}/trailing-nul.out"; then
  pass 'trailing-nul: a trailing NUL record boundary adds no phantom element'
else
  fail "trailing-nul: expected a two-element array with no phantom third, got exit ${rc}"
  cat -- "${work}/trailing-nul.out" "${work}/trailing-nul.err" >&2
fi

# 7. unterminated-last-record — a producer's final record with no
# trailing NUL (a truncated or malformed producer; `git ls-files -z` and
# `find -print0` always terminate every record, including the last) is
# kept rather than dropped. `read -r -d ''` reports such a record as a
# read failure even though it populated the variable, so a loop keyed
# only on read's exit status silently skips it — the exact silent-drop
# failure this library exists to end. Four elements (not a size already
# used by another scenario above) so this scenario's own asserted
# substring cannot be satisfied by a sibling's output.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'unterminated-last-record' '[0]="wolf" [1]="fox" [2]="owl" [3]="hare"' '
function stub_unterminated() { printf "%s\0%s\0%s\0%s" wolf fox owl hare; }
declare -a out=()
enumerate_into out "stub_unterminated" stub_unterminated
printf "size=%d\n" "${#out[@]}"
declare -p out
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'size=4' "${work}/unterminated-last-record.out" &&
  grep --fixed-strings --quiet -- '[0]="wolf" [1]="fox" [2]="owl" [3]="hare"' \
    "${work}/unterminated-last-record.out"; then
  pass 'unterminated-last-record: a NUL-less final record is kept, not dropped, exit 0'
else
  fail "unterminated-last-record: expected a four-element array including the unterminated final record, got exit ${rc}"
  cat -- "${work}/unterminated-last-record.out" "${work}/unterminated-last-record.err" >&2
fi

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
