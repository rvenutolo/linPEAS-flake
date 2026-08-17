#!/usr/bin/env bash
# tests/refresh-test-harnesses.test.sh
#
# Round-trip, drift and derivation harness for
# scripts/refresh-test-harnesses.sh.
#
# The live half proves the generator agrees with the tree it ships in: a
# regenerate followed by --check must be clean, and the census line must
# report as many harnesses as tests/ actually holds, so a derivation that
# quietly skipped files cannot pass by rendering a smaller doc twice.
#
# The fixture half drives synthetic scan roots, one per derivation rule.
# Each root is small enough that the whole expected census is stated in
# the assertion, so a rule that stops firing changes a row rather than a
# count nobody reads.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${REPO_ROOT}/scripts/lib/enumerate.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-test-harnesses.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/test-harnesses"
readonly DOC="${REPO_ROOT}/docs/reference/test-harnesses.md"

# The empty-scan assertion is the subject of one row here, so an ambient
# opt-out inherited from a wrapper would turn that row green without the
# generator doing anything.
unset LINT_ALLOW_EMPTY_SCAN

failures=0
work="$(mktemp --directory)"
live_backup=''
# One trap does every restore job: a second `trap ... EXIT` would replace
# this one and leave the tracked doc holding whatever the live round-trip
# last wrote.
trap 'rm --recursive --force -- "${work}"; [[ -n "${live_backup:-}" && -f "${live_backup}" ]] && { cp -- "${live_backup}" "${DOC}"; rm --force -- "${live_backup}"; }' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Run the generator against one scan root and output path,
# capturing the whole observable outcome under work/<name>. Sets `rc` in
# the calling scope rather than returning it through a command
# substitution: a substitution forks a subshell, and the discrimination
# gate's pool lives in globals a subshell's exit would discard.
# @arg $1 scenario name  @arg $2 scan root  @arg $3 output doc path
# @arg $@ extra generator arguments
function run_gen() {
  local -r name="$1" root="$2" doc="$3"
  shift 3
  rc=0
  env "TESTS_DIR_OVERRIDE=${root}" "DOC_OVERRIDE=${doc}" \
    bash "${SCRIPT}" "$@" \
    >"${work}/${name}.out" 2>"${work}/${name}.err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${work}/${name}.outcome"
}

# @description Assert one scenario ended non-zero carrying a diagnostic,
# and record it with the discrimination gate.
# @arg $1 scenario name  @arg $2 expected exit code
# @arg $3 expected stderr substring  @arg $4 human description
function expect_failure() {
  local -r name="$1" want="$2" expect="$3" description="$4"
  harness_assert_record "${name}" "${expect}" \
    "${work}/${name}.outcome" "${work}/${name}.out" "${work}/${name}.err"
  if [[ ${rc} -eq ${want} ]] &&
    grep --fixed-strings --quiet -- "${expect}" "${work}/${name}.err"; then
    pass "${description} (exit ${rc})"
  else
    fail "${description}: expected exit ${want} naming ${expect@Q}, got exit ${rc}"
    cat -- "${work}/${name}.out" "${work}/${name}.err" >&2
  fi
}

# @description Assert one scenario generated a doc holding an expected
# fragment, and record the doc as the scenario's observable output.
# @arg $1 scenario name  @arg $2 generated doc path
# @arg $3 expected doc substring  @arg $4 human description
function expect_doc() {
  local -r name="$1" doc="$2" expect="$3" description="$4"
  # A generator run that died before writing leaves no doc behind. Copy
  # into a stand-in that always exists, so the gate records an empty
  # observation instead of returning a missing-file error that errexit
  # turns into an aborted run — which would skip every row after this one
  # and the discrimination census with them. A scenario that produced
  # nothing is a failure this row has to report out loud.
  local -r observed="${work}/${name}.doc"
  : >"${observed}"
  if [[ -f ${doc} ]]; then
    cat -- "${doc}" >"${observed}"
  fi
  harness_assert_record "${name}" "${expect}" \
    "${work}/${name}.outcome" "${observed}"
  if [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --quiet -- "${expect}" "${observed}"; then
    pass "${description}"
  else
    fail "${description}: expected exit 0 and ${expect@Q} in the census, got exit ${rc}"
    cat -- "${work}/${name}.err" >&2
  fi
}

function main() {
  # 1. Round trip on a two-harness tree. The generate half is this
  #    scenario's setup rather than a record of its own: both halves print
  #    the same census line, so recording them separately would hand the
  #    gate two outputs neither of which any substring could separate.
  local doc_good="${work}/good.md"
  run_gen 'good-generate' "${FIXTURES}/good" "${doc_good}"
  local generate_rc="${rc}"
  run_gen 'good-check' "${FIXTURES}/good" "${doc_good}" --check
  # Stating every count of a two-harness tree makes this row fail on a
  # derivation that drops a harness, a subject source or a fixture
  # directory, rather than only on one that crashes.
  local -r good_census='2 harness(es), 2 with a declared subject (1 assignment, 1 annotation), 1 with fixture directories, 1 fixture directory(ies) referenced'
  harness_assert_record 'good round trip' "${good_census}" \
    "${work}/good-check.outcome" "${work}/good-check.out" "${work}/good-check.err"
  harness_assert_also "${doc_good} is up to date"
  if [[ ${generate_rc} -eq 0 ]] && [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --quiet -- "${good_census}" "${work}/good-check.out"; then
    pass 'generate then --check is clean and reports the tree it walked'
  else
    fail "good round trip: generate exit ${generate_rc}, check exit ${rc}"
    cat -- "${work}/good-generate.err" "${work}/good-check.err" >&2
  fi

  # 2. A hand-edited row must read as drift, not as a doc the generator
  #    can leave alone.
  local doc_drift="${work}/drift.md"
  run_gen 'drift-seed' "${FIXTURES}/good" "${doc_drift}"
  # shellcheck disable=SC2016 # literal backticks in a markdown table row
  printf '| `tests/check-injected.test.sh` | `scripts/check-injected.sh` | — |\n' \
    >>"${doc_drift}"
  run_gen 'drift' "${FIXTURES}/good" "${doc_drift}" --check
  expect_failure 'drift' 1 'drift — run scripts/refresh-test-harnesses.sh and commit' \
    '--check reports a hand-edited census as drift'

  # 3. An absent doc is a could-not-run, not drift: exit 1 would send the
  #    operator to regenerate-and-commit a file that was never there.
  run_gen 'doc-missing' "${FIXTURES}/good" "${work}/absent.md" --check
  expect_failure 'doc-missing' 2 'not found; run without --check to bootstrap' \
    '--check on a missing doc is a could-not-run'

  # 4. A scan root holding no harness must not render an empty census and
  #    call it fresh.
  run_gen 'empty-root' "${FIXTURES}/empty" "${work}/empty.md"
  expect_failure 'empty-root' 2 'matched 0 files via test harnesses' \
    'an empty scan root is a could-not-run'

  # 5. Two subject declarations can disagree, so the census refuses to
  #    pick one.
  run_gen 'both-declared' "${FIXTURES}/both-declared" "${work}/both.md"
  expect_failure 'both-declared' 2 'declares a subject twice' \
    'a harness declaring a subject twice is rejected'

  # 6. No declaration at all would render an unknown subject.
  run_gen 'no-subject' "${FIXTURES}/no-subject" "${work}/no-subject.md"
  expect_failure 'no-subject' 2 'declares no subject' \
    'a harness declaring no subject is rejected'

  # 7. A fixture directory no harness names is a tree the census cannot
  #    describe — either a harness lost its reference or the directory is
  #    dead weight.
  run_gen 'orphan-fixture' "${FIXTURES}/orphan-fixture" "${work}/orphan.md"
  expect_failure 'orphan-fixture' 2 'tests/fixtures/unreferenced is named by no harness' \
    'a fixture directory no harness names is rejected'

  # 8. Three path literals on one harness collapse into one sorted cell.
  local doc_multi="${work}/multi.md"
  run_gen 'multi-fixture' "${FIXTURES}/multi-fixture" "${doc_multi}"
  # shellcheck disable=SC2016 # literal backticks in a markdown table cell
  expect_doc 'multi-fixture' "${doc_multi}" \
    '`tests/fixtures/zeta`, `tests/fixtures/zeta-extra`, `tests/fixtures/zeta-more`' \
    'three fixture directories render sorted in one cell'

  # 9. A fixture directory reached only through an override has no path
  #    literal naming it, so the header annotation is the only source.
  local doc_annotated="${work}/annotated.md"
  run_gen 'annotated-fixture' "${FIXTURES}/annotated-fixture" "${doc_annotated}"
  # shellcheck disable=SC2016 # literal backticks in a markdown table cell
  expect_doc 'annotated-fixture' "${doc_annotated}" '`tests/fixtures/eta`' \
    'a fixture directory named only by an annotation is rendered'

  # 10. The live tree. The census line must report the harness count the
  #     tree actually holds, so a derivation that skipped files cannot
  #     round-trip its way to green.
  # This count is the expectation the census line is scored against, so an
  # empty match set would not fail the row — it would assert that the
  # generator found zero harnesses, and a generator that skipped the whole
  # tree would round-trip its way to green against it.
  local -a live_harnesses=()
  glob_into live_harnesses 'live harness tree' "${REPO_ROOT}/tests/*.test.sh"
  local -r live_expect="test-harnesses: ok — ${#live_harnesses[@]} harness(es),"
  if [[ -f ${DOC} ]]; then
    live_backup="$(mktemp)"
    cp -- "${DOC}" "${live_backup}"
  fi
  rc=0
  bash "${SCRIPT}" >"${work}/live-generate.out" 2>"${work}/live-generate.err" || rc=$?
  local live_generate_rc="${rc}"
  rc=0
  bash "${SCRIPT}" --check \
    >"${work}/live.out" 2>"${work}/live.err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${work}/live.outcome"
  harness_assert_record 'live round trip' "${live_expect}" \
    "${work}/live.outcome" "${work}/live.out" "${work}/live.err"
  if [[ ${live_generate_rc} -eq 0 ]] && [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --quiet -- "${live_expect}" "${work}/live.out"; then
    pass "live tree round trip is clean over ${#live_harnesses[@]} harness(es)"
  else
    fail "live round trip: generate exit ${live_generate_rc}, check exit ${rc}"
    cat -- "${work}/live-generate.err" "${work}/live.err" >&2
  fi

  # 11. Sections are derived from the harness basename, and a section with
  #     no members is omitted rather than rendered empty.
  local doc_sections="${work}/sections.md"
  run_gen 'sections' "${FIXTURES}/good" "${doc_sections}"
  expect_doc 'sections' "${doc_sections}" '## Library harnesses' \
    'a lib- harness lands in its own section'
  # Read the stand-in expect_doc leaves behind, which exists whether or not
  # the generator got as far as writing a census.
  local -r sections_seen="${work}/sections.doc"
  if grep --fixed-strings --quiet -- '## Check harnesses' "${sections_seen}" &&
    ! grep --fixed-strings --quiet -- '## Refresh harnesses' "${sections_seen}"; then
    pass 'a section with no members is omitted'
  else
    fail 'section grouping: expected Check present and Refresh absent'
    cat -- "${sections_seen}" >&2
  fi

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall passed\n'
}

main "$@"
