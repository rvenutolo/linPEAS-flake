#!/usr/bin/env bash
# tests/refresh-pin-parity.test.sh
#
# Round-trip, drift and derivation harness for
# scripts/refresh-pin-parity.sh.
#
# Every fixture root is small enough that the whole expected census is
# stated in the assertion, so a derivation rule that stops firing changes
# a row rather than a count nobody reads. Group membership is asserted on
# whole rendered lines: a bullet list is a sequence of lines that are all
# substrings of a longer leaked list, so a substring match would survive
# exactly the leak each row exists to catch.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-pin-parity.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/pin-parity"

# The breadth assertion is the subject of a row here, so an ambient
# opt-out inherited from a wrapper would turn it green without the
# generator doing anything.
unset LINT_ALLOW_EMPTY_SCAN

failures=0
work="$(mktemp --directory)"
trap 'rm --recursive --force -- "${work}"' EXIT

function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# @description Write a throwaway page carrying the managed markers at
# column zero, the way the real section holds them.
# @arg $1 destination path
function seed_page() {
  local -r dest="$1"
  {
    printf '# Heading\n\n'
    printf 'intro paragraph\n\n'
    printf '## Canonical pin shape\n\n'
    printf -- '<!-- BEGIN pin-parity -->\n\n'
    printf 'stale content\n\n'
    printf -- '<!-- END pin-parity -->\n\n'
    printf 'outro paragraph\n'
  } >"${dest}"
}

# @description Run the generator against one fixture root and page,
# capturing the whole observable outcome under work/<name>. Sets `rc` in
# the calling scope rather than returning it through a command
# substitution: a substitution forks a subshell, and the discrimination
# gate's pool lives in globals a subshell's exit would discard.
# @arg $1 scenario name  @arg $2 fixture root  @arg $3 page path
# @arg $@ extra generator arguments
function run_gen() {
  local -r name="$1" root="$2" page="$3"
  shift 3
  rc=0
  env "PIN_PARITY_ROOT_OVERRIDE=${root}" \
    "PIN_PARITY_DOC_OVERRIDE=${page}" \
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

function main() {
  # 1. Round trip. The generate half is this scenario's setup rather than
  #    a record of its own: both halves print the same census line, so
  #    recording them separately would hand the gate two outputs no
  #    substring could separate.
  local page_good="${work}/good.md"
  seed_page "${page_good}"
  run_gen 'good-generate' "${FIXTURES}/good" "${page_good}"
  local generate_rc="${rc}"
  run_gen 'good-check' "${FIXTURES}/good" "${page_good}" --check
  # Stating every count of a five-file tree makes this row fail on a
  # derivation that drops the tests/ filter, the near-miss filter or the
  # group split, rather than only on one that crashes.
  local -r good_census='3 file(s) carrying the pin shape: 2 enforcement, 1 documentation'
  local -r good_census_line="pin-parity: ok — ${good_census}"
  harness_assert_record 'good round trip' "${good_census}" \
    "${work}/good-check.outcome" "${work}/good-check.out" "${work}/good-check.err"
  harness_assert_also "${page_good} is up to date"
  if [[ ${generate_rc} -eq 0 ]] && [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --line-regexp --quiet -- "${good_census_line}" "${work}/good-check.out"; then
    pass 'generate then --check is clean and reports the tree it walked'
  else
    fail "good round trip: generate exit ${generate_rc}, check exit ${rc}"
    cat -- "${work}/good-generate.err" "${work}/good-check.err" >&2
  fi

  # 2. Group membership, asserted over one rendered page so the gate
  #    holds one record for one observation. Whole-line matches
  #    throughout: a bullet list is a sequence of lines each of which is
  #    a substring of a longer leaked list, so a substring assertion
  #    would survive the very leak these rows exist to catch. The two
  #    absences are checked on the same page as the two presences, so an
  #    absence can never be satisfied by a run that rendered nothing.
  local page_groups="${work}/groups.md"
  local groups_ok=0
  seed_page "${page_groups}"
  run_gen 'groups' "${FIXTURES}/good" "${page_groups}"
  # shellcheck disable=SC2016 # literal backticks in the rendered markdown
  harness_assert_record 'groups' '- `cliff.toml`' \
    "${work}/groups.outcome" "${page_groups}"
  # shellcheck disable=SC2016 # literal backticks in the rendered markdown
  harness_assert_also '- `docs/page.md`'
  # shellcheck disable=SC2016 # literal backticks in the rendered markdown
  if [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --line-regexp --quiet -- '- `cliff.toml`' "${page_groups}" &&
    grep --fixed-strings --line-regexp --quiet -- '- `docs/page.md`' "${page_groups}" &&
    ! grep --fixed-strings --line-regexp --quiet -- '- `tests/fixture.json`' "${page_groups}" &&
    ! grep --fixed-strings --line-regexp --quiet -- '- `near-miss.yml`' "${page_groups}"; then
    groups_ok=1
  fi
  if [[ ${groups_ok} -eq 1 ]]; then
    pass 'the groups split by path, excluding tests/ and the action-SHA near-miss'
  else
    fail "groups: the rendered page did not split correctly (exit ${rc})"
    cat -- "${page_groups}" "${work}/groups.err" >&2
  fi

  # 3. An empty group states itself in prose. A bolded label followed by
  #    nothing reads as truncated output rather than as a group that
  #    genuinely holds nothing.
  local page_nodocs="${work}/no-docs.md"
  local nodocs_ok=0
  seed_page "${page_nodocs}"
  run_gen 'no-docs' "${FIXTURES}/no-docs" "${page_nodocs}"
  # Recorded on the bullet unique to this fixture root, not on the
  # empty-group sentence: that sentence is by design the same text the
  # all-empty scenario renders, so recording it would hand the gate two
  # scenarios no substring separates. The sentence is still asserted
  # below — a row can check more than it registers.
  # shellcheck disable=SC2016 # literal backticks in the rendered markdown
  harness_assert_record 'no-docs' '- `pattern.toml`' \
    "${work}/no-docs.outcome" "${page_nodocs}"
  # shellcheck disable=SC2016 # literal backticks in the rendered markdown
  if [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --line-regexp --quiet -- '- `pattern.toml`' "${page_nodocs}" &&
    grep --fixed-strings --line-regexp --quiet -- 'No tracked documentation carries the shape.' "${page_nodocs}"; then
    nodocs_ok=1
  fi
  if [[ ${nodocs_ok} -eq 1 ]]; then
    pass 'an empty documentation group renders a sentence rather than a bare label'
  else
    fail "no-docs: expected a pattern.toml bullet and the empty-documentation sentence (exit ${rc})"
    cat -- "${page_nodocs}" "${work}/no-docs.err" >&2
  fi

  # 4. A hand-edited block must read as drift, not as a page the
  #    generator can leave alone.
  local page_drift="${work}/drift.md"
  seed_page "${page_drift}"
  run_gen 'drift-seed' "${FIXTURES}/good" "${page_drift}"
  # Inserted right after the BEGIN marker rather than appended at EOF: a
  # line appended outside the markers is copied through unchanged by both
  # the current doc and the freshly-regenerated one, so cmp would find no
  # difference and --check would wrongly call a hand-edited block clean.
  sed --in-place '/^<!-- BEGIN pin-parity -->$/a\an injected line' "${page_drift}"
  run_gen 'drift' "${FIXTURES}/good" "${page_drift}" --check
  expect_failure 'drift' 1 'is stale. Run scripts/refresh-pin-parity.sh and commit.' \
    '--check reports a hand-edited page as drift'

  # 5. An absent page is a could-not-run: exit 1 would send the operator
  #    to regenerate a block that has nowhere to go.
  run_gen 'page-missing' "${FIXTURES}/good" "${work}/absent.md" --check
  expect_failure 'page-missing' 2 'not found' \
    '--check on a missing page is a could-not-run'

  # 6 and 7. Each marker is required, and the diagnostics name which one
  #    is gone — an operator who deleted one is not helped by learning
  #    that "a marker" is missing.
  local page_no_begin="${work}/no-begin.md"
  seed_page "${page_no_begin}"
  grep --invert-match --fixed-strings -- 'BEGIN pin-parity' \
    "${page_no_begin}" >"${page_no_begin}.tmp"
  mv -- "${page_no_begin}.tmp" "${page_no_begin}"
  run_gen 'no-begin' "${FIXTURES}/good" "${page_no_begin}"
  expect_failure 'no-begin' 2 'BEGIN marker missing from' \
    'a page that lost its BEGIN marker is a could-not-run'

  local page_no_end="${work}/no-end.md"
  seed_page "${page_no_end}"
  grep --invert-match --fixed-strings -- 'END pin-parity' \
    "${page_no_end}" >"${page_no_end}.tmp"
  mv -- "${page_no_end}.tmp" "${page_no_end}"
  run_gen 'no-end' "${FIXTURES}/good" "${page_no_end}"
  expect_failure 'no-end' 2 'END marker missing from' \
    'a page that lost its END marker is a could-not-run'

  # 8. A tree where nothing carries the literal is a could-not-run. This
  #    is the state a completed scheme migration leaves behind, and it is
  #    the one failure a rendered block could not show: an empty list
  #    reads as "nothing enforces the shape", which is the opposite of
  #    what a migration produced.
  local page_none="${work}/no-matches.md"
  seed_page "${page_none}"
  run_gen 'no-matches' "${FIXTURES}/no-matches" "${page_none}"
  expect_failure 'no-matches' 2 'files carrying the canonical pin shape' \
    'a tree where nothing carries the shape is a could-not-run'

  # 9. Under LINT_ALLOW_EMPTY_SCAN=1 a genuinely empty match set must
  #    render both groups' prose rather than two bare labels. The opt-out
  #    is set only for this invocation, via `env` on the call itself —
  #    the file-top `unset` stays in force for the breadth row above,
  #    which shares a fixture root with this one.
  local page_empty="${work}/empty.md"
  seed_page "${page_empty}"
  rc=0
  env "PIN_PARITY_ROOT_OVERRIDE=${FIXTURES}/no-matches" \
    "PIN_PARITY_DOC_OVERRIDE=${page_empty}" \
    "LINT_ALLOW_EMPTY_SCAN=1" \
    bash "${SCRIPT}" \
    >"${work}/empty.out" 2>"${work}/empty.err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${work}/empty.outcome"
  local -r empty_census_line='pin-parity: ok — 0 file(s) carrying the pin shape: 0 enforcement, 0 documentation'
  local -r empty_enforcement_line='No tracked enforcement or configuration file carries the shape.'
  harness_assert_record 'empty' "${empty_census_line}" \
    "${work}/empty.outcome" "${work}/empty.out" "${work}/empty.err" \
    "${page_empty}"
  harness_assert_also "${empty_enforcement_line}"
  if [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --line-regexp --quiet -- "${empty_census_line}" "${work}/empty.out" &&
    grep --fixed-strings --line-regexp --quiet -- "${empty_enforcement_line}" "${page_empty}"; then
    pass 'LINT_ALLOW_EMPTY_SCAN=1 over an empty match set states both groups in prose'
  else
    fail "empty: expected exit 0, census ${empty_census_line@Q}, sentence ${empty_enforcement_line@Q}, got exit ${rc}"
    cat -- "${work}/empty.out" "${work}/empty.err" >&2
  fi

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall passed\n'
}

main "$@"
