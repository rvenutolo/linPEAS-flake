#!/usr/bin/env bash
# tests/lib-generates.test.sh — proves scripts/lib/generates.sh reads the
# `@generates` / `@generates-block` annotations out of a script's comment
# header and nowhere else, emits one unit-separated record per
# declaration in file order, keeps duplicates so a caller can count them,
# and reports an unreadable input by returning non-zero rather than by
# emitting a short record stream a caller would score as agreement.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
LIB="${REPO_ROOT}/scripts/lib/generates.sh"
readonly LIB
export GENERATES_LIB="${LIB}"

failures=0
rc=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# The driver is written once and run per scenario with the scenario's
# input paths as argv, so every scenario exercises one call shape and the
# only thing that varies is what the lib was pointed at. It captures the
# record stream the way the documented callers do — a command
# substitution guarded by `||` — because that is the shape in which
# errexit is suppressed and the returned status is the only signal a read
# fault produces. Records are rendered with the separator expanded into
# readable `kind=`/`path=`/`script=` fields so a scenario can assert on
# the exact bytes of a record without embedding a control byte in the
# assertion.
cat >"${work}/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
source "${GENERATES_LIB}"

status=0
records="$(generator_declarations "$@")" || status=$?

declare -a rendered=()
kind=""
path=""
origin=""
# A here-string of an empty variable yields one empty element rather than
# zero, so an empty stream still enters the loop once and has to be
# dropped explicitly.
while IFS=$'\037' read -r kind path origin; do
  [[ -n ${kind} ]] || continue
  rendered+=("record: kind=${kind} path=${path} script=${origin}")
done <<<"${records}"

label=""
for input in "$@"; do
  label+="${label:+ }${input}"
done

printf 'summary: inputs=%s status=%d count=%d\n' \
  "${label}" "${status}" "${#rendered[@]}"
if ((${#rendered[@]} > 0)); then
  printf '%s\n' "${rendered[@]}"
fi
DRIVER

# @description Run the driver over the given input paths as its own bash
# process, capture its streams, and record the outcome with the
# cross-scenario discrimination gate. Sets `rc` (a plain, non-local
# variable of the calling scope) rather than returning through a `$()`
# command substitution: a substitution forks a subshell, and
# `harness_assert_record`'s pool state lives in globals that a subshell's
# exit would discard, leaving the parent with no recorded scenarios.
# @arg $1 scenario name  @arg $2 asserted substring ('' if none)
# @arg $@ input paths handed to `generator_declarations`
function run_scenario() {
  local -r name="$1" substring="$2"
  shift 2
  local -r out="${work}/${name}.out"
  local -r err="${work}/${name}.err"
  local -r outcome="${work}/${name}.outcome"
  rc=0
  bash "${work}/driver.sh" "$@" >"${out}" 2>"${err}" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${outcome}"
  harness_assert_record "${name}" "${substring}" "${outcome}" "${out}" "${err}"
}

# @description Compare the record lines a scenario emitted, in order,
# against the exact lines expected. Order is part of the contract — the
# stream is documented as file order — and a set comparison would accept
# a parser that emitted the block form before the plain one. An exact
# count is asserted too, so a duplicate the lib silently dropped fails
# here rather than passing as "the expected record is present".
# @arg $1 scenario name  @arg $@ expected record lines, in order
function assert_records() {
  local -r name="$1"
  shift
  local -a expected=("$@")
  local -a actual=()
  local line
  while IFS= read -r line; do
    [[ ${line} == 'record: '* ]] || continue
    actual+=("${line}")
  done <"${work}/${name}.out"

  if [[ ${#actual[@]} -ne ${#expected[@]} ]]; then
    fail "${name}: expected ${#expected[@]} record(s), got ${#actual[@]}"
    cat -- "${work}/${name}.out" "${work}/${name}.err" >&2
    return 1
  fi
  local i
  for ((i = 0; i < ${#expected[@]}; i++)); do
    if [[ ${actual[i]} != "${expected[i]}" ]]; then
      fail "${name}: record ${i} is ${actual[i]@Q}, expected ${expected[i]@Q}"
      return 1
    fi
  done
  return 0
}

# Fixture scripts. Every fixture declares a doc path no other fixture
# declares, so a scenario's asserted record line cannot be satisfied by a
# sibling scenario's output — the discrimination gate would otherwise
# score the whole sweep on one shared record.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# one-generates.sh' \
  '#' \
  '# @generates docs/reference/one.md' \
  'set -Eeuo pipefail' \
  >"${work}/one-generates.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# one-block.sh' \
  '#' \
  '# @generates-block docs/reference/block.md' \
  'set -Eeuo pipefail' \
  >"${work}/one-block.sh"

# Plain form first, block form second, so the emitted order proves file
# order rather than a parser that happens to group by kind.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# both-kinds.sh' \
  '#' \
  '# @generates docs/reference/both-plain.md' \
  '# @generates-block docs/reference/both-block.md' \
  'set -Eeuo pipefail' \
  >"${work}/both-kinds.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# no-declarations.sh' \
  '#' \
  '# @description a header carrying no output declaration at all' \
  'set -Eeuo pipefail' \
  >"${work}/no-declarations.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# below-header.sh' \
  'set -Eeuo pipefail' \
  '# @generates docs/reference/below.md' \
  'printf "body\n"' \
  >"${work}/below-header.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# blank-in-header.sh' \
  '' \
  '# @generates docs/reference/after-blank.md' \
  'set -Eeuo pipefail' \
  >"${work}/blank-in-header.sh"

# No trailing newline on the final line: `read` reports failure on such a
# line even after populating the variable, so a loop that trusts read's
# status alone drops the last declaration in the file.
printf '#!/usr/bin/env bash\n# @generates docs/reference/final-line.md' \
  >"${work}/no-trailing-newline.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# pair-first.sh' \
  '#' \
  '# @generates docs/reference/pair-first.md' \
  'set -Eeuo pipefail' \
  >"${work}/pair-first.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# pair-second.sh' \
  '#' \
  '# @generates docs/reference/pair-second.md' \
  'set -Eeuo pipefail' \
  >"${work}/pair-second.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  '# duplicate.sh' \
  '#' \
  '# @generates docs/reference/twice.md' \
  '# @generates docs/reference/twice.md' \
  'set -Eeuo pipefail' \
  >"${work}/duplicate.sh"

# 1. one-generates — a single `@generates` line yields one record whose
# kind is the plain form and whose third field names the file it came
# from.
readonly REC_ONE="record: kind=generates path=docs/reference/one.md script=${work}/one-generates.sh"
run_scenario 'one-generates' "${REC_ONE}" "${work}/one-generates.sh"
if [[ ${rc} -eq 0 ]] && assert_records 'one-generates' "${REC_ONE}"; then
  pass 'one-generates: one @generates line yields one generates record, exit 0'
else
  fail "one-generates: expected exit 0 + one generates record, got exit ${rc}"
fi

# 2. one-generates-block — the block form is its own kind. `@generates`
# is a proper prefix of `@generates-block`, so a parser whose plain
# pattern does not demand whitespace between the annotation name and its
# path reports every block declaration under the plain kind; this
# scenario is what separates the two names.
readonly REC_BLOCK="record: kind=generates-block path=docs/reference/block.md script=${work}/one-block.sh"
run_scenario 'one-generates-block' "${REC_BLOCK}" "${work}/one-block.sh"
if [[ ${rc} -eq 0 ]] && assert_records 'one-generates-block' "${REC_BLOCK}"; then
  pass 'one-generates-block: the block form yields kind generates-block, exit 0'
else
  fail "one-generates-block: expected exit 0 + one generates-block record, got exit ${rc}"
fi

# 3. both-kinds — a file declaring both forms yields both records, in the
# order the lines appear rather than grouped by kind.
readonly REC_BOTH_PLAIN="record: kind=generates path=docs/reference/both-plain.md script=${work}/both-kinds.sh"
readonly REC_BOTH_BLOCK="record: kind=generates-block path=docs/reference/both-block.md script=${work}/both-kinds.sh"
run_scenario 'both-kinds' "${REC_BOTH_PLAIN}" "${work}/both-kinds.sh"
harness_assert_also "${REC_BOTH_BLOCK}"
if [[ ${rc} -eq 0 ]] &&
  assert_records 'both-kinds' "${REC_BOTH_PLAIN}" "${REC_BOTH_BLOCK}"; then
  pass 'both-kinds: both forms yield two records in file order, exit 0'
else
  fail "both-kinds: expected exit 0 + two records in file order, got exit ${rc}"
fi

# 4. no-declarations — a readable file declaring nothing is a clean
# answer, not a fault: the caller decides whether an empty list is drift.
readonly SUM_NONE="summary: inputs=${work}/no-declarations.sh status=0 count=0"
run_scenario 'no-declarations' "${SUM_NONE}" "${work}/no-declarations.sh"
if [[ ${rc} -eq 0 ]] && assert_records 'no-declarations'; then
  pass 'no-declarations: a header with no annotation yields no records, exit 0'
else
  fail "no-declarations: expected exit 0 + zero records, got exit ${rc}"
fi

# 5. below-header — an annotation after the first non-comment,
# non-blank line is body text, not a declaration. Without the terminator
# the parser would credit a script with output it names in a comment
# beside the code that writes something else.
readonly SUM_BELOW="summary: inputs=${work}/below-header.sh status=0 count=0"
run_scenario 'below-header' "${SUM_BELOW}" "${work}/below-header.sh"
if [[ ${rc} -eq 0 ]] && assert_records 'below-header'; then
  pass 'below-header: an annotation below the header is not matched, exit 0'
else
  fail "below-header: expected exit 0 + zero records, got exit ${rc}"
fi

# 6. blank-line-in-header — a blank line separates paragraphs of a
# comment header rather than ending it, so an annotation after one is
# still a declaration.
readonly REC_AFTER_BLANK="record: kind=generates path=docs/reference/after-blank.md script=${work}/blank-in-header.sh"
run_scenario 'blank-line-in-header' "${REC_AFTER_BLANK}" "${work}/blank-in-header.sh"
if [[ ${rc} -eq 0 ]] && assert_records 'blank-line-in-header' "${REC_AFTER_BLANK}"; then
  pass 'blank-line-in-header: a blank line does not terminate the header, exit 0'
else
  fail "blank-line-in-header: expected exit 0 + one record, got exit ${rc}"
fi

# 7. no-trailing-newline — the declaration on a final line with no
# newline after it is still a declaration.
readonly REC_FINAL="record: kind=generates path=docs/reference/final-line.md script=${work}/no-trailing-newline.sh"
run_scenario 'no-trailing-newline' "${REC_FINAL}" "${work}/no-trailing-newline.sh"
if [[ ${rc} -eq 0 ]] && assert_records 'no-trailing-newline' "${REC_FINAL}"; then
  pass 'no-trailing-newline: a final line with no newline is still matched, exit 0'
else
  fail "no-trailing-newline: expected exit 0 + one record, got exit ${rc}"
fi

# 8. two-scripts — one call over several paths attributes each record to
# the file it came from, so a caller naming the offending generator in a
# diagnostic names the right one.
readonly REC_PAIR_FIRST="record: kind=generates path=docs/reference/pair-first.md script=${work}/pair-first.sh"
readonly REC_PAIR_SECOND="record: kind=generates path=docs/reference/pair-second.md script=${work}/pair-second.sh"
run_scenario 'two-scripts' "${REC_PAIR_FIRST}" \
  "${work}/pair-first.sh" "${work}/pair-second.sh"
harness_assert_also "${REC_PAIR_SECOND}"
if [[ ${rc} -eq 0 ]] &&
  assert_records 'two-scripts' "${REC_PAIR_FIRST}" "${REC_PAIR_SECOND}"; then
  pass 'two-scripts: each record carries its own source script, exit 0'
else
  fail "two-scripts: expected exit 0 + one record per script, got exit ${rc}"
fi

# 9. unreadable-path — a path that cannot be read is a could-not-run the
# caller has to see. The status is the only signal, because the stream
# itself is indistinguishable from a file that declared nothing. An
# absent path is the deterministic form of unreadable: a mode-000 file
# stays readable to a test runner with the privilege to ignore it.
readonly SUM_UNREADABLE="summary: inputs=${work}/absent.sh status=1 count=0"
run_scenario 'unreadable-path' "${SUM_UNREADABLE}" "${work}/absent.sh"
if [[ ${rc} -eq 0 ]] &&
  assert_records 'unreadable-path' &&
  grep --fixed-strings --quiet -- 'status=1' "${work}/unreadable-path.out" &&
  [[ ! -s ${work}/unreadable-path.err ]]; then
  pass 'unreadable-path: an unreadable input returns non-zero with no records'
else
  fail "unreadable-path: expected a non-zero return and no records, got exit ${rc}"
  cat -- "${work}/unreadable-path.out" "${work}/unreadable-path.err" >&2
fi

# 10. duplicate-declaration — the same path declared twice in one file
# yields two records. `check-size-label-ignores.sh` counts declarations
# including duplicates while its maps deduplicate by path, so a stream
# that collapsed them would hand that caller a count it did not ask for.
readonly REC_TWICE="record: kind=generates path=docs/reference/twice.md script=${work}/duplicate.sh"
readonly SUM_TWICE="summary: inputs=${work}/duplicate.sh status=0 count=2"
run_scenario 'duplicate-declaration' "${SUM_TWICE}" "${work}/duplicate.sh"
harness_assert_also "${REC_TWICE}"
if [[ ${rc} -eq 0 ]] &&
  assert_records 'duplicate-declaration' "${REC_TWICE}" "${REC_TWICE}"; then
  pass 'duplicate-declaration: a repeated declaration yields two records, exit 0'
else
  fail "duplicate-declaration: expected exit 0 + two identical records, got exit ${rc}"
fi

harness_assert_verify || failures=$((failures + 1))

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
