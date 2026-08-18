#!/usr/bin/env bash
# tests/refresh-ephemeral-refs-gap.test.sh
#
# Round-trip, drift and derivation harness for
# scripts/refresh-ephemeral-refs-gap.sh.
#
# Each fixture root is small enough that the whole expected census is
# stated in the assertion, so a derivation rule that stops firing changes
# a row rather than a count nobody reads. The two breadth rows are kept
# on separate roots because they answer different operator questions —
# a complement that came back empty, and a complement that holds no
# comment to read — and one diagnostic would misdescribe one of them.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/refresh-ephemeral-refs-gap.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/ephemeral-refs-gap"

# The breadth assertions are the subject of two rows here, so an ambient
# opt-out inherited from a wrapper would turn both green without the
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

# @description Write a throwaway page carrying the managed markers at the
# four-space continuation indent the real page uses.
# @arg $1 destination path
function seed_page() {
  local -r dest="$1"
  {
    printf 'intro paragraph\n\n'
    printf -- '- **A bullet.** Leading prose:\n\n'
    printf '    <!-- BEGIN ephemeral-refs-gap -->\n\n'
    printf '    stale content\n\n'
    printf '    <!-- END ephemeral-refs-gap -->\n\n'
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
  env "EPHEMERAL_REFS_GAP_ROOT_OVERRIDE=${root}" \
    "EPHEMERAL_REFS_GAP_DOC_OVERRIDE=${page}" \
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

# @description Assert one scenario rendered a page holding an expected
# line as a complete line, and record the page as the scenario's
# observable output. Every label-list row uses this rather than a
# substring match: the rendered line is a `, `-joined, `LC_ALL=C`-sorted
# list, so an expected list is always a suffix of a longer list that
# leaked one more label in ahead of it — `` `.toml`, `justfile`. `` is a
# suffix of `` `.sh`, `.toml`, `justfile`. ``, and `` `.toml`. `` is a
# suffix of `` `.awk`, `.toml`. ``. A substring assertion on either would
# stay green through exactly the regression it exists to catch — a type
# filter or an allowlist entry that stopped excluding something.
# Anchoring to the whole line, indent included, closes that: a leaked
# label changes the line's start, not just its middle.
# @arg $1 scenario name  @arg $2 page path
# @arg $3 expected exact line  @arg $4 human description
function expect_page_line() {
  local -r name="$1" page="$2" expect="$3" description="$4"
  # A run that died before writing leaves no page behind. Copy into a
  # stand-in that always exists, so the gate records an empty observation
  # instead of a missing-file error that errexit turns into an aborted
  # run — which would skip every row after this one and the
  # discrimination census with them.
  local -r observed="${work}/${name}.page"
  : >"${observed}"
  if [[ -f ${page} ]]; then
    cat -- "${page}" >"${observed}"
  fi
  harness_assert_record "${name}" "${expect}" \
    "${work}/${name}.outcome" "${observed}"
  if [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --line-regexp --quiet -- "${expect}" "${observed}"; then
    pass "${description}"
  else
    fail "${description}: expected exit 0 and exact line ${expect@Q} in the page, got exit ${rc}"
    cat -- "${work}/${name}.err" >&2
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
  # Stating every count of a four-source tree makes this row fail on a
  # derivation that drops the type filter, the comment filter or a label,
  # rather than only on one that crashes.
  local -r good_census='3 unclaimed source(s), 2 carrying comments, 2 type label(s), 0 blocking shape(s)'
  # The local check below matches the whole stdout line, not this
  # substring: a count that grew from 3 to, say, 13 would still render
  # "...13 unclaimed source(s)...", and "3 unclaimed source(s)" is a
  # trailing substring of that too — the same unanchored-substring gap a
  # leaked type label hides behind, just on digits instead of labels. The
  # census is a single stdout line by construction, so anchoring to it
  # whole costs nothing. `good_census` itself stays substring-shaped
  # because harness_assert_record's cross-scenario check is a deliberate
  # substring search over other scenarios' raw output, not this
  # single-scenario line check.
  local -r good_census_line="ephemeral-refs-gap: ok — ${good_census}"
  harness_assert_record 'good round trip' "${good_census}" \
    "${work}/good-check.outcome" "${work}/good-check.out" "${work}/good-check.err"
  harness_assert_also 'is up to date'
  # The live-tree scenario below is also a clean, already-generated run,
  # so it legitimately prints this same banner. The two rows still
  # discriminate on their census substrings, which differ because the
  # fixture root and the live tree hold different populations.
  harness_assert_exempt 'is up to date' 'live' \
    'both rows are a clean --check on an already-generated tree, just different trees'
  if [[ ${generate_rc} -eq 0 ]] && [[ ${rc} -eq 0 ]] &&
    grep --fixed-strings --line-regexp --quiet -- "${good_census_line}" "${work}/good-check.out"; then
    pass 'generate then --check is clean and reports the tree it walked'
  else
    fail "good round trip: generate exit ${generate_rc}, check exit ${rc}"
    cat -- "${work}/good-generate.err" "${work}/good-check.err" >&2
  fi

  # 2. The claimed type and the comment-less source are excluded for two
  #    different reasons, and the rendered label list is where that shows.
  local page_labels="${work}/labels.md"
  seed_page "${page_labels}"
  run_gen 'labels' "${FIXTURES}/good" "${page_labels}"
  # Matched as the complete line (four-space indent included), not a
  # substring: `claimed.sh` sorts first under LC_ALL=C, so a broken type
  # filter would still leave `` `.toml`, `justfile`. `` sitting as a
  # substring of the leaked line and a substring match would not notice.
  # shellcheck disable=SC2016 # literal backticks in markdown output
  expect_page_line 'labels' "${page_labels}" '    `.toml`, `justfile`.' \
    'the label list renders sorted and excludes claimed and comment-less sources'

  # 3. A hand-edited block must read as drift, not as a page the
  #    generator can leave alone.
  local page_drift="${work}/drift.md"
  seed_page "${page_drift}"
  run_gen 'drift-seed' "${FIXTURES}/good" "${page_drift}"
  # Inserted right after the BEGIN marker rather than appended at EOF: a
  # line appended outside the markers is copied through unchanged by both
  # the current doc and the freshly-regenerated one, so cmp would find no
  # difference and --check would wrongly call a hand-edited block clean.
  sed --in-place '/    <!-- BEGIN ephemeral-refs-gap -->/a\    an injected line' \
    "${page_drift}"
  run_gen 'drift' "${FIXTURES}/good" "${page_drift}" --check
  expect_failure 'drift' 1 'is stale. Run scripts/refresh-ephemeral-refs-gap.sh and commit.' \
    '--check reports a hand-edited page as drift'

  # 4. An absent page is a could-not-run: exit 1 would send the operator
  #    to regenerate a block that has nowhere to go.
  run_gen 'page-missing' "${FIXTURES}/good" "${work}/absent.md" --check
  expect_failure 'page-missing' 2 'not found' \
    '--check on a missing page is a could-not-run'

  # 5 and 6. Each marker is required, and the diagnostics name which one
  #    is gone — an operator who deleted one is not helped by learning
  #    that "a marker" is missing.
  local page_no_begin="${work}/no-begin.md"
  seed_page "${page_no_begin}"
  grep --invert-match --fixed-strings -- 'BEGIN ephemeral-refs-gap' \
    "${page_no_begin}" >"${page_no_begin}.tmp"
  mv -- "${page_no_begin}.tmp" "${page_no_begin}"
  run_gen 'no-begin' "${FIXTURES}/good" "${page_no_begin}"
  expect_failure 'no-begin' 2 'BEGIN marker missing from' \
    'a page that lost its BEGIN marker is a could-not-run'

  local page_no_end="${work}/no-end.md"
  seed_page "${page_no_end}"
  grep --invert-match --fixed-strings -- 'END ephemeral-refs-gap' \
    "${page_no_end}" >"${page_no_end}.tmp"
  mv -- "${page_no_end}.tmp" "${page_no_end}"
  run_gen 'no-end' "${FIXTURES}/good" "${page_no_end}"
  expect_failure 'no-end' 2 'END marker missing from' \
    'a page that lost its END marker is a could-not-run'

  # 7. Every source claimed by an extractor leaves an empty complement.
  #    The block describes what the lint does not read, so a complement
  #    that came back empty is a scan that read nothing, not a tree with
  #    nothing to report.
  local page_claimed="${work}/claimed-only.md"
  seed_page "${page_claimed}"
  run_gen 'claimed-only' "${FIXTURES}/claimed-only" "${page_claimed}"
  expect_failure 'claimed-only' 2 'unclaimed sources' \
    'a tree whose every source is claimed is a could-not-run'

  # 8. A non-empty complement holding no comment is the other breadth
  #    failure, and carries its own diagnostic.
  local page_quiet="${work}/no-comments.md"
  seed_page "${page_quiet}"
  run_gen 'no-comments' "${FIXTURES}/no-comments" "${page_quiet}"
  expect_failure 'no-comments' 2 'no unclaimed source carries a full-line comment' \
    'a complement with no comment to read is a could-not-run'

  # 9. A blocking shape inside the complement is refused. Rendering a
  #    count would publish a page whose surrounding prose argues the
  #    opposite.
  local page_violating="${work}/violating.md"
  seed_page "${page_violating}"
  run_gen 'violating' "${FIXTURES}/violating" "${page_violating}"
  expect_failure 'violating' 2 'a blocking ephemeral-reference shape appears in a file type no extractor claims' \
    'a blocking shape in the gap is refused rather than rendered'

  # 10. The allowlist still applies to the complement. Asserted on the
  #     rendered label list rather than on an absence, so a scan that
  #     read nothing at all cannot pass this row.
  local page_allow="${work}/allowlisted.md"
  seed_page "${page_allow}"
  run_gen 'allowlisted' "${FIXTURES}/allowlisted" "${page_allow}"
  # Matched as the complete line: a leaked `tests/fixtures/**` source
  # would sort ahead of `.toml` under LC_ALL=C and render as
  # `` `.awk`, `.toml`. ``, which still contains `` `.toml`. `` as a
  # substring. A substring assertion would pass on exactly the allowlist
  # regression this row exists to catch.
  # shellcheck disable=SC2016 # literal backticks in markdown output
  expect_page_line 'allowlisted' "${page_allow}" '    `.toml`.' \
    'a source under a skipped path is excluded while its sibling is kept'

  # 11. A union that matches nothing would render the empty verdict over
  #     any corpus at all, and no count or exit status would show it.
  seed_page "${work}/canary.md"
  rc=0
  env "EPHEMERAL_REFS_GAP_ROOT_OVERRIDE=${FIXTURES}/violating" \
    "EPHEMERAL_REFS_GAP_DOC_OVERRIDE=${work}/canary.md" \
    "EPHEMERAL_REFS_GAP_UNION_OVERRIDE=zzz-matches-nothing-zzz" \
    bash "${SCRIPT}" \
    >"${work}/canary.out" 2>"${work}/canary.err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${work}/canary.outcome"
  expect_failure 'canary' 2 'the blocking union no longer matches the issue canary' \
    'a union that stopped matching a class is refused before anything is read'

  # 12. The live tree. The generator ships with the page it generates, so
  #     a --check that is not clean on a freshly-generated tree means the
  #     committed block and the tree disagree. The label list is asserted
  #     from the tree rather than from the generator's own output: an
  #     expectation the generator produced would let a generator that
  #     scanned nothing round-trip its way to green.
  local live_labels
  # shellcheck disable=SC2016 # literal backticks in markdown output
  live_labels="$(sed --quiet 's/^    \(`\..*`\)\.$/\1/p' \
    "${REPO_ROOT}/docs/development/linting.md" | head --lines=1)"
  rc=0
  bash "${SCRIPT}" --check >"${work}/live.out" 2>"${work}/live.err" || rc=$?
  printf 'harness-assert-outcome: exit=%d\n' "${rc}" >"${work}/live.outcome"
  # The recorded substring is this run's own census tail, read back
  # rather than hardcoded: the live tree's counts move as the repo
  # grows, and a constant fixed here would go stale on its own. Reading
  # it back still discriminates against the fixture scenarios above,
  # whose counts are small and fixed by their fixture roots.
  local live_census
  live_census="$(sed --quiet 's/^ephemeral-refs-gap: ok — \(.*\)$/\1/p' \
    "${work}/live.out" | head --lines=1)"
  harness_assert_record 'live' "${live_census}" \
    "${work}/live.outcome" "${work}/live.out" "${work}/live.err"
  # Anchored to the whole census line rather than a bare substring
  # search for `0 blocking shape(s)`: that substring is also the tail of
  # a hypothetical `10 blocking shape(s)`, the exact leaked-digit defect
  # the label-list rows above were rewritten to close. Capturing the
  # digits between the last comma and the literal suffix, over the
  # entire line (`^...$`), means only a genuine zero can satisfy it.
  local live_blocking_count
  live_blocking_count="$(sed --regexp-extended --quiet \
    's/^ephemeral-refs-gap: ok — .*, ([0-9]+) blocking shape\(s\)$/\1/p' \
    "${work}/live.out" | head --lines=1)"
  if [[ ${rc} -eq 0 ]] && [[ -n ${live_labels} ]] &&
    [[ ${live_blocking_count} == '0' ]]; then
    pass "live tree round trip is clean over ${live_labels}"
  else
    fail "live round trip: check exit ${rc}, labels read as ${live_labels@Q}, blocking count read as ${live_blocking_count@Q}"
    cat -- "${work}/live.err" >&2
  fi

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d failure(s)\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall passed\n'
}

main "$@"
