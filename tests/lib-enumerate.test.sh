#!/usr/bin/env bash
# @subject scripts/lib/enumerate.sh
# tests/lib-enumerate.test.sh — proves scripts/lib/enumerate.sh turns a
# NUL-delimited producer into an array with no line-oriented data loss,
# that producer failure and an empty scan set are both surfaced as exit 2
# rather than silently accepted as an empty result, and that a final
# record missing its trailing NUL is kept rather than dropped. Also
# proves the glob analogue: a pattern set matching nothing is exit 2
# rather than a clean tree, a path holding a space stays one element, and
# the caller's `nullglob` and `globstar` settings are what they were on
# return.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly LIB="${REPO_ROOT}/scripts/lib/enumerate.sh"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

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

# 8. mktemp-fails — an unwritable TMPDIR makes the temp-file helper
# report a could-not-run (exit 2) rather than letting mktemp's own exit
# status (1) leak through `set -Eeuo pipefail` as the calling script's
# exit code — a could-not-run reported as "ran and found a violation"
# inside the one function whose job is making sure that never happens.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'mktemp-fails' 'cannot create a temp file (TMPDIR=/nonexistent-tmpdir-enumerate-test)' '
export TMPDIR="/nonexistent-tmpdir-enumerate-test"
function stub_never_runs() { printf "%s\0" ignored; }
declare -a out=()
enumerate_into out "stub_never_runs" stub_never_runs
printf "size=%d\n" "${#out[@]}"
'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'cannot create a temp file (TMPDIR=/nonexistent-tmpdir-enumerate-test)' \
    "${work}/mktemp-fails.err"; then
  pass 'mktemp-fails: an unwritable TMPDIR is exit 2, stderr names the failure'
else
  fail "mktemp-fails: expected exit 2 + temp-file failure message, got exit ${rc}"
  cat -- "${work}/mktemp-fails.out" "${work}/mktemp-fails.err" >&2
fi

# Fixture trees for the glob scenarios. Each lives in its own directory
# under the harness work dir so one scenario's match set cannot reach
# another's, and none of them collides with the per-scenario script and
# capture files run_scenario writes directly into that dir.
readonly multi="${work}/fixture-multi"
readonly empty="${work}/fixture-empty"
readonly spaced="${work}/fixture-spaced"
readonly starred="${work}/fixture-starred"
mkdir --parents -- "${multi}" "${empty}" "${spaced}" \
  "${starred}/sub/deep"
: >"${multi}/alpha-one.aa"
: >"${multi}/alpha-two.aa"
: >"${multi}/beta-one.bb"
: >"${spaced}/space probe.aa"
: >"${starred}/top.txt"
: >"${starred}/sub/mid.txt"
: >"${starred}/sub/deep/low.txt"

# 9. glob-multiple — two patterns fill one array in pattern order, and a
# caller who never touched `nullglob` still has it unset on return.
run_scenario 'glob-multiple' 'multiple=3' "
declare -a out=()
glob_into out 'multi probe' \"${multi}/*.aa\" \"${multi}/*.bb\"
printf 'multiple=%d\n' \"\${#out[@]}\"
printf 'order=%s,%s,%s\n' \"\${out[0]##*/}\" \"\${out[1]##*/}\" \"\${out[2]##*/}\"
if shopt -q nullglob; then printf 'nullglob-after=set\n'; else printf 'nullglob-after=unset\n'; fi
"
harness_assert_also 'order=alpha-one.aa,alpha-two.aa,beta-one.bb'
harness_assert_also 'nullglob-after=unset'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'multiple=3' "${work}/glob-multiple.out" &&
  grep --fixed-strings --quiet -- 'order=alpha-one.aa,alpha-two.aa,beta-one.bb' \
    "${work}/glob-multiple.out" &&
  grep --fixed-strings --quiet -- 'nullglob-after=unset' "${work}/glob-multiple.out"; then
  pass 'glob-multiple: two patterns fill three elements in pattern order, nullglob left unset, exit 0'
else
  fail "glob-multiple: expected exit 0 + three elements in pattern order + nullglob unset, got exit ${rc}"
  cat -- "${work}/glob-multiple.out" "${work}/glob-multiple.err" >&2
fi

# 10. glob-empty — patterns matching nothing under an existing root are
# exit 2, not a clean tree. The shared escape-hatch hint is claimed here
# as well as by the enumerate-side empty scenario: both paths really do
# print it, so each also carries a substring naming its own path.
run_scenario 'glob-empty' 'matched 0 files via glob probe set' "
declare -a out=()
glob_into out 'glob probe set' \"${empty}/*.aa\" \"${empty}/*.bb\"
printf 'unreached=%d\n' \"\${#out[@]}\"
"
harness_assert_also 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'matched 0 files via glob probe set' \
    "${work}/glob-empty.err" &&
  grep --fixed-strings --quiet -- 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate' \
    "${work}/glob-empty.err"; then
  pass 'glob-empty: a pattern set matching nothing is exit 2, stderr names the label and the hint'
else
  fail "glob-empty: expected exit 2 + label and LINT_ALLOW_EMPTY_SCAN hint, got exit ${rc}"
  cat -- "${work}/glob-empty.out" "${work}/glob-empty.err" >&2
fi

# 11. glob-empty-allowed — the same empty match set, opted out via
# LINT_ALLOW_EMPTY_SCAN, is exit 0 with an empty array, and a caller who
# had `nullglob` set still has it set on return.
run_scenario 'glob-empty-allowed' 'allowed=0' "
shopt -s nullglob
export LINT_ALLOW_EMPTY_SCAN=1
declare -a out=()
glob_into out 'allowed probe' \"${empty}/*.aa\"
printf 'allowed=%d\n' \"\${#out[@]}\"
if shopt -q nullglob; then printf 'nullglob-after=set\n'; else printf 'nullglob-after=unset\n'; fi
"
harness_assert_also 'nullglob-after=set'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'allowed=0' "${work}/glob-empty-allowed.out" &&
  grep --fixed-strings --quiet -- 'nullglob-after=set' "${work}/glob-empty-allowed.out"; then
  pass 'glob-empty-allowed: LINT_ALLOW_EMPTY_SCAN=1 turns the same empty match set exit 0, nullglob left set'
else
  fail "glob-empty-allowed: expected exit 0 + empty array + nullglob still set, got exit ${rc}"
  cat -- "${work}/glob-empty-allowed.out" "${work}/glob-empty-allowed.err" >&2
fi

# 12. glob-space-name — a match holding a space is one element. The
# expansion runs under an empty IFS, so pathname expansion happens
# without word splitting; `declare -p` captures the element boundary
# unambiguously.
run_scenario 'glob-space-name' 'spaced=1' "
declare -a out=()
glob_into out 'spaced probe' \"${spaced}/*.aa\"
printf 'spaced=%d\n' \"\${#out[@]}\"
declare -p out
"
harness_assert_also 'space probe.aa")'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'spaced=1' "${work}/glob-space-name.out" &&
  grep --fixed-strings --quiet -- 'space probe.aa")' "${work}/glob-space-name.out"; then
  pass 'glob-space-name: a match containing a space stays one element, exit 0'
else
  fail "glob-space-name: expected one element carrying the space, got exit ${rc}"
  cat -- "${work}/glob-space-name.out" "${work}/glob-space-name.err" >&2
fi

# 13. glob-no-nullglob — a caller that has explicitly unset `nullglob`
# still gets exit 2 on an empty match set. This is the scenario the
# expand-inside-the-function decision exists for: a call site expanding
# its own patterns without `nullglob` would hand the function the literal
# unexpanded pattern, which counts as one match and vouches for exactly
# the tree the assertion exists to catch.
run_scenario 'glob-no-nullglob' 'matched 0 files via nullglob-unset probe' "
shopt -u nullglob
declare -a out=()
glob_into out 'nullglob-unset probe' \"${empty}/*.aa\"
printf 'unreached=%d\n' \"\${#out[@]}\"
"
harness_assert_also 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'matched 0 files via nullglob-unset probe' \
    "${work}/glob-no-nullglob.err" &&
  grep --fixed-strings --quiet -- 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate' \
    "${work}/glob-no-nullglob.err"; then
  pass 'glob-no-nullglob: an unset nullglob still yields exit 2, not one literal-pattern element'
else
  fail "glob-no-nullglob: expected exit 2 with no literal-pattern element, got exit ${rc}"
  cat -- "${work}/glob-no-nullglob.out" "${work}/glob-no-nullglob.err" >&2
fi

# 14. glob-globstar-set — a caller with `globstar` set keeps the reach it
# already had, and still has the option set on return.
run_scenario 'glob-globstar-set' 'starset=3' "
shopt -s globstar
declare -a out=()
glob_into out 'globstar probe' \"${starred}/**/*.txt\"
printf 'starset=%d\n' \"\${#out[@]}\"
if shopt -q globstar; then printf 'globstar-after=set\n'; else printf 'globstar-after=unset\n'; fi
"
harness_assert_also 'globstar-after=set'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'starset=3' "${work}/glob-globstar-set.out" &&
  grep --fixed-strings --quiet -- 'globstar-after=set' "${work}/glob-globstar-set.out"; then
  pass 'glob-globstar-set: a set globstar recurses and stays set, exit 0'
else
  fail "glob-globstar-set: expected three recursive matches and globstar still set, got exit ${rc}"
  cat -- "${work}/glob-globstar-set.out" "${work}/glob-globstar-set.err" >&2
fi

# 15. glob-globstar-unset — the same pattern against the same tree with
# `globstar` unset reaches one directory level only, and the option is
# still unset on return: the function neither widens nor narrows what the
# caller asked for.
run_scenario 'glob-globstar-unset' 'starunset=1' "
shopt -u globstar
declare -a out=()
glob_into out 'globstar probe' \"${starred}/**/*.txt\"
printf 'starunset=%d\n' \"\${#out[@]}\"
if shopt -q globstar; then printf 'globstar-after=set\n'; else printf 'globstar-after=unset\n'; fi
"
harness_assert_also 'globstar-after=unset'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'starunset=1' "${work}/glob-globstar-unset.out" &&
  grep --fixed-strings --quiet -- 'globstar-after=unset' "${work}/glob-globstar-unset.out"; then
  pass 'glob-globstar-unset: an unset globstar reaches one level and stays unset, exit 0'
else
  fail "glob-globstar-unset: expected one single-level match and globstar still unset, got exit ${rc}"
  cat -- "${work}/glob-globstar-unset.out" "${work}/glob-globstar-unset.err" >&2
fi

# 16. filter-selects-one — three paths, filtering on one basename selects
# exactly the path with that basename.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-selects-one' 'selone=1' '
declare -a out=()
filter_into out "filter-selects-one probe" "b.yml" "a.yml" "b.yml" "c.yml"
printf "selone=%d\n" "${#out[@]}"
declare -p out
'
harness_assert_also '[0]="b.yml"'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'selone=1' "${work}/filter-selects-one.out" &&
  grep --fixed-strings --quiet -- '[0]="b.yml"' "${work}/filter-selects-one.out"; then
  pass 'filter-selects-one: a matching basename selects exactly that path, exit 0'
else
  fail "filter-selects-one: expected one selected element, got exit ${rc}"
  cat -- "${work}/filter-selects-one.out" "${work}/filter-selects-one.err" >&2
fi

# 17. filter-identity-empty-value — an empty filter value selects every
# input path, in input order.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-identity-empty-value' 'identity=3' '
declare -a out=()
filter_into out "filter-identity-empty-value probe" "" "a.yml" "b.yml" "c.yml"
printf "identity=%d\n" "${#out[@]}"
declare -p out
'
harness_assert_also '[0]="a.yml" [1]="b.yml" [2]="c.yml"'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'identity=3' "${work}/filter-identity-empty-value.out" &&
  grep --fixed-strings --quiet -- '[0]="a.yml" [1]="b.yml" [2]="c.yml"' \
    "${work}/filter-identity-empty-value.out"; then
  pass 'filter-identity-empty-value: an empty filter value selects every input path, exit 0'
else
  fail "filter-identity-empty-value: expected all three paths selected, got exit ${rc}"
  cat -- "${work}/filter-identity-empty-value.out" "${work}/filter-identity-empty-value.err" >&2
fi

# 18. filter-selects-nothing — a filter value naming no path in the input
# set is exit 2, not the silent clean-tree line an empty loop body would
# otherwise produce.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-selects-nothing' 'selected 0 of' '
declare -a out=()
filter_into out "filter-selects-nothing probe" "no-such.yml" "a.yml" "b.yml" "c.yml"
printf "unreached=%d\n" "${#out[@]}"
'
harness_assert_also 'filter no-such.yml selected 0 of 3 files for filter-selects-nothing probe'
harness_assert_also 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'filter no-such.yml selected 0 of 3 files for filter-selects-nothing probe' \
    "${work}/filter-selects-nothing.err"; then
  pass 'filter-selects-nothing: a filter matching nothing is exit 2, stderr names the filter, count and label'
else
  fail "filter-selects-nothing: expected exit 2 + filter/count/label in stderr, got exit ${rc}"
  cat -- "${work}/filter-selects-nothing.out" "${work}/filter-selects-nothing.err" >&2
fi

# 19. filter-empty-input-set — an empty filter value against no input
# paths is exit 2 naming the empty input set, distinct from a filter that
# matched nothing against a non-empty input set.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-empty-input-set' 'the input scan set was empty' '
declare -a out=()
filter_into out "filter-empty-input-set probe" ""
printf "unreached=%d\n" "${#out[@]}"
'
harness_assert_also 'selected 0 files for filter-empty-input-set probe'
harness_assert_also 'LINT_ALLOW_EMPTY_SCAN=1 if this is deliberate'
if [[ ${rc} -eq 2 ]] &&
  grep --fixed-strings --quiet -- 'selected 0 files for filter-empty-input-set probe' \
    "${work}/filter-empty-input-set.err" &&
  grep --fixed-strings --quiet -- 'the input scan set was empty' \
    "${work}/filter-empty-input-set.err"; then
  pass 'filter-empty-input-set: an empty input scan set is exit 2, stderr names the empty-input cause'
else
  fail "filter-empty-input-set: expected exit 2 + empty-input-set message, got exit ${rc}"
  cat -- "${work}/filter-empty-input-set.out" "${work}/filter-empty-input-set.err" >&2
fi

# 20. filter-empty-allowed — the same filter matching nothing, opted out
# via LINT_ALLOW_EMPTY_SCAN, is exit 0 with an empty array.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-empty-allowed' 'filternone=0' '
export LINT_ALLOW_EMPTY_SCAN=1
declare -a out=()
filter_into out "filter-empty-allowed probe" "no-such.yml" "a.yml" "b.yml" "c.yml"
printf "filternone=%d\n" "${#out[@]}"
declare -p out
'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'filternone=0' "${work}/filter-empty-allowed.out"; then
  pass 'filter-empty-allowed: LINT_ALLOW_EMPTY_SCAN=1 turns a filter matching nothing exit 0'
else
  fail "filter-empty-allowed: expected exit 0 + empty array, got exit ${rc}"
  cat -- "${work}/filter-empty-allowed.out" "${work}/filter-empty-allowed.err" >&2
fi

# 21. filter-basename-not-substring — the comparison is basename equality,
# not a suffix test: a filter of `b.yml` must not also select `ab.yml`.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-basename-not-substring' 'notsuffix=1' '
declare -a out=()
filter_into out "filter-basename-not-substring probe" "b.yml" "a/b.yml" "x/ab.yml"
printf "notsuffix=%d\n" "${#out[@]}"
declare -p out
'
harness_assert_also '[0]="a/b.yml"'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'notsuffix=1' "${work}/filter-basename-not-substring.out" &&
  grep --fixed-strings --quiet -- '[0]="a/b.yml"' "${work}/filter-basename-not-substring.out"; then
  pass 'filter-basename-not-substring: an equal basename is selected, a matching suffix is not, exit 0'
else
  fail "filter-basename-not-substring: expected only the equal-basename path selected, got exit ${rc}"
  cat -- "${work}/filter-basename-not-substring.out" "${work}/filter-basename-not-substring.err" >&2
fi

# 22. filter-path-with-space — a selected path holding a space stays one
# element.
# shellcheck disable=SC2016 # snippet is bash source text for a child process, not text to expand here
run_scenario 'filter-path-with-space' 'spacefilter=1' '
declare -a out=()
filter_into out "filter-path-with-space probe" "b.yml" "dir with space/b.yml"
printf "spacefilter=%d\n" "${#out[@]}"
declare -p out
'
harness_assert_also 'dir with space/b.yml")'
if [[ ${rc} -eq 0 ]] &&
  grep --fixed-strings --quiet -- 'spacefilter=1' "${work}/filter-path-with-space.out" &&
  grep --fixed-strings --quiet -- 'dir with space/b.yml")' "${work}/filter-path-with-space.out"; then
  pass 'filter-path-with-space: a selected path holding a space stays one element, exit 0'
else
  fail "filter-path-with-space: expected one element carrying the space, got exit ${rc}"
  cat -- "${work}/filter-path-with-space.out" "${work}/filter-path-with-space.err" >&2
fi

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
