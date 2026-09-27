#!/usr/bin/env bash
# tests/check-notify-arms.test.sh
#
# Failure-mode harness for scripts/check-notify-arms.sh.
#
# Every scenario copies the base fixture into a scratch git repository and
# edits it there, so inputs the formatter would repair (an unclosed marker,
# a marker opening a line, a workflow YAML cannot parse) are built at run
# time rather than checked in.
# shellcheck disable=SC2016 # backticks and ${{ }} are literal fixture text

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-notify-arms.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-notify-arms"
readonly BASE="${FIXTURES}/base"

failures=0
LAST_STDERR=''
LAST_NAME=''
ROOT=''

# @description Make a fresh scratch root holding a copy of the base
# fixture, in its own git repository, and point ROOT at it.
function fresh_root() {
  ROOT="$(mktemp --directory)"
  cp --recursive -- "${BASE}/." "${ROOT}/"
  git -C "${ROOT}" init --quiet
  # The caller's global excludes would otherwise decide what is untracked.
  git -C "${ROOT}" config core.excludesFile /dev/null
}

# @description Replace one exact string in a file under ROOT, failing the
# harness when it does not occur exactly once, so an edit that silently
# matched nothing cannot turn a failure scenario into a clean pass.
# @arg $1 path relative to ROOT
# @arg $2 text to replace
# @arg $3 replacement
function edit() {
  local -r path="${ROOT}/$1" old="$2" new="$3"
  local content
  content="$(<"${path}")"
  local rest="${content#*"${old}"}"
  if [[ ${rest} == "${content}" || ${rest} == *"${old}"* ]]; then
    printf 'HARNESS BUG: %q does not occur exactly once in %s\n' "${old}" "$1" >&2
    exit 1
  fi
  printf '%s\n' "${content/"${old}"/"${new}"}" >"${path}"
}

# @description Run the script against ROOT; assert exit code, stderr, and
# stdout. The clean path's summary carries the marker tallies and the scan
# breadth, which is what tells two clean scenarios apart.
# @arg $1 scenario name
# @arg $2 expected exit code (0, 1, or 2)
# @arg $3 expected stderr substring (empty string skips the check)
# @arg $4 expected stdout substring (empty string skips the check)
function run_scenario() {
  local -r name="$1" expected_exit="$2" expected_stderr="$3" expected_stdout="${4:-}"
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  (cd -- "${REPO_ROOT}" && SCAN_ROOT_OVERRIDE="${ROOT}" "${SCRIPT}") \
    >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    printf 'stdout was:\n' >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  if [[ -n ${expected_stdout} ]]; then
    harness_assert_also "${expected_stdout}"
  fi
  rm --force -- "${outcome_file}" "${stdout_file}" "${LAST_STDERR}"
  rm --recursive --force -- "${ROOT}"
  LAST_STDERR="${stderr_file}"
  LAST_NAME="${name}"
}

# @description Assert one more substring appears in the last scenario's
# stderr, and register it for the discrimination check.
# @arg $1 expected stderr substring
function also_expect() {
  local -r substring="$1"
  if ! grep --fixed-strings --quiet -- "${substring}" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${LAST_NAME}" "${substring}" >&2
    printf 'stderr was:\n' >&2
    cat -- "${LAST_STDERR}" >&2
    failures=$((failures + 1))
  fi
  harness_assert_also "${substring}"
}

# @description Assert a substring is absent from the last scenario's
# stderr.
# @arg $1 substring that must not appear
function refute_stderr() {
  local -r substring="$1"
  if grep --fixed-strings --quiet -- "${substring}" "${LAST_STDERR}"; then
    printf 'FAIL: %s — stderr unexpectedly holds %q\n' "${LAST_NAME}" "${substring}" >&2
    cat -- "${LAST_STDERR}" >&2
    failures=$((failures + 1))
  fi
}

readonly TALLY='finding=4 failure=6 cancelled=6 success=0 skipped=0 non-pr=4'
readonly CLEAN="10 body marker(s) and 10 docs marker(s) match the arms of 10 scanner notify job(s) (${TALLY}); scanned 6 workflow(s) and 1 Markdown file(s)"
readonly DOC='docs/scanners.md'
readonly CQ='.github/workflows/codeql.yml'
readonly SC='.github/workflows/scorecard-drift-check.yml'
readonly CQ_FINDING_GATE="if: always() && github.event_name != 'pull_request' && needs.analyze.result == 'failure' && needs.analyze.outputs.has-finding == 'true'"
readonly CQ_INFRA_DOC='and `codeql-infra` <!-- notify-arms: codeql.yml/notify-infra = failure cancelled non-pr -->.'
readonly CQ_INFRA_BODY='An infrastructure failure. <!-- notify-arms: codeql.yml/notify-infra = failure cancelled non-pr -->'
readonly SC_DOC='A failed or cancelled scorecard run opens `scorecard-drift` <!-- notify-arms: scorecard-drift-check.yml/notify = failure cancelled -->.'

function main() {
  # --- derivation, clean paths ---

  # The base holds all ten scanner notify jobs, a marker in each body and
  # each in the docs, a syntax example in a code span and a fence, and a
  # non-scanner notify job whose gate and result are outside the grammar
  # but that no marker names.
  fresh_root
  run_scenario clean-passes 0 '' "${CLEAN}"

  # One scenario per job, each reaching the base derivation by another
  # route, so a regression in any one fails it:
  #   - codeql notify-finding compares upper-case literals, which GitHub
  #     matches case-insensitively;
  #   - octoscan notify-finding wraps its gate in ${{ }};
  #   - scorecard reads `&&` tighter than `||`: failure files on every
  #     event and cancelled only off pull_request, so no non-pr token,
  #     where the wrong precedence would give both arms non-pr;
  #   - zizmor negates: not-success admits skipped too, which the
  #     composite ignores;
  #   - an 11th docs marker, in a second file, lists its tokens out of
  #     order and states the cancel word only in a code span;
  #   - the codeql infra body says "cancellation" though bodies are exempt.
  fresh_root
  edit "${CQ}" "needs.analyze.result == 'failure' && needs.analyze.outputs.has-finding == 'true'" \
    "needs.analyze.result == 'FAILURE' && needs.analyze.outputs.has-finding == 'TRUE'"
  edit '.github/workflows/octoscan.yml' \
    "if: always() && github.event_name != 'pull_request' && needs.scan.result == 'failure' && needs.scan.outputs.has-finding == 'true'" \
    "if: \${{ always() && github.event_name != 'pull_request' && needs.scan.result == 'failure' && needs.scan.outputs.has-finding == 'true' }}"
  edit "${SC}" 'if: always()' \
    "if: always() && (needs.drift-check.result == 'failure' || needs.drift-check.result == 'cancelled' && github.event_name != 'pull_request')"
  edit '.github/workflows/zizmor-drift-check.yml' 'if: always()' \
    "if: always() && !(needs.drift-check.result == 'success')"
  printf 'An infrastructure run whose job ends `cancelled` <!-- notify-arms: codeql.yml/notify-infra = non-pr cancelled failure -->.\n' \
    >"${ROOT}/docs/second.md"
  edit "${CQ}" "${CQ_INFRA_BODY}" \
    'An infrastructure failure, never a cancellation. <!-- notify-arms: codeql.yml/notify-infra = failure cancelled non-pr -->'
  run_scenario grammar-variants-pass 0 '' \
    "10 body marker(s) and 11 docs marker(s) match the arms of 10 scanner notify job(s) (${TALLY}); scanned 6 workflow(s) and 2 Markdown file(s)"

  # A literal `result: failure` behind an always() gate files on every
  # result of the watched job, success and skipped included; the tokens
  # exist to say so.
  fresh_root
  edit "${SC}" 'result: ${{ needs.drift-check.result }}' 'result: failure'
  edit "${SC}" 'scorecard-drift-check.yml/notify = failure cancelled -->' \
    'scorecard-drift-check.yml/notify = failure cancelled success skipped -->'
  edit "${DOC}" 'scorecard-drift-check.yml/notify = failure cancelled -->' \
    'scorecard-drift-check.yml/notify = failure cancelled success skipped -->'
  run_scenario literal-result-all-arms-passes 0 '' \
    '(finding=4 failure=6 cancelled=6 success=1 skipped=1 non-pr=4)'

  # A marker in a gitignored file, in the untracked Claude-behavior tree,
  # under tests/fixtures/ or in CHANGELOG.md is outside the scan set.
  fresh_root
  mkdir --parents "${ROOT}/.claude" "${ROOT}/tests/fixtures"
  printf 'docs/ignored.md\n' >"${ROOT}/.gitignore"
  local bogus='Text <!-- notify-arms: codeql.yml/nope = bogus -->.'
  printf '%s\n' "${bogus}" >"${ROOT}/docs/ignored.md"
  printf '%s\n' "${bogus}" >"${ROOT}/.claude/x.md"
  printf '%s\n' "${bogus}" >"${ROOT}/tests/fixtures/x.md"
  printf '%s\n' "${bogus}" >"${ROOT}/CHANGELOG.md"
  printf '%s\n' "${bogus}" >"${ROOT}/docs/releases.md"
  printf 'Nothing declared here.\n' >"${ROOT}/docs/plain.md"
  run_scenario excluded-paths-passes 0 '' \
    "10 body marker(s) and 10 docs marker(s) match the arms of 10 scanner notify job(s) (${TALLY}); scanned 6 workflow(s) and 2 Markdown file(s)"

  # A tracked file in the Claude-behavior tree is read.
  fresh_root
  mkdir --parents "${ROOT}/.claude"
  printf 'Text <!-- notify-arms: codeql.yml/nope = finding -->.\n' >"${ROOT}/.claude/x.md"
  git -C "${ROOT}" add .claude/x.md
  run_scenario tracked-claude-file-fails 1 '.claude/x.md:1: marker names codeql.yml/nope, which is not a notify-workflow-result job'

  # A marker may name a notify job outside the scanner workflows, and is
  # checked against its derived arms.
  fresh_root
  edit '.github/workflows/other.yml' "if: always() && contains(github.ref, 'main')" 'if: always()'
  edit '.github/workflows/other.yml' 'needs: [build, deploy]' 'needs: build'
  edit '.github/workflows/other.yml' \
    "result: \${{ (needs.build.result == 'failure' || needs.deploy.result == 'failure') && 'failure' || 'success' }}" \
    'result: ${{ needs.build.result }}'
  printf 'Other pages a failure <!-- notify-arms: other.yml/notify = failure -->.\n' >>"${ROOT}/${DOC}"
  run_scenario other-workflow-marker-fails 1 \
    'docs/scanners.md:33: marker for other.yml/notify declares "failure"; the workflow files on "failure cancelled"'

  # --- a workflow change the prose did not follow ---

  # An arm added to a gate fails every marker that restates the old set.
  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" \
    "if: always() && github.event_name != 'pull_request' && (needs.analyze.result == 'cancelled' || needs.analyze.result == 'failure' && needs.analyze.outputs.has-finding == 'true')"
  run_scenario arm-added-fails 1 \
    'docs/scanners.md:6: marker for codeql.yml/notify-finding declares "finding non-pr"; the workflow files on "finding cancelled non-pr"'
  also_expect '.github/workflows/codeql.yml (job notify-finding body):1: marker for codeql.yml/notify-finding declares "finding non-pr"; the workflow files on "finding cancelled non-pr"'

  # Dropping the pull_request exclusion drops the non-pr token.
  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" \
    "if: always() && needs.analyze.result == 'failure' && needs.analyze.outputs.has-finding == 'true'"
  run_scenario pr-scope-dropped-fails 1 \
    'marker for codeql.yml/notify-finding declares "finding non-pr"; the workflow files on "finding"'

  # A watched job that declares no has-finding output has no finding arm:
  # the output reads empty, so a gate demanding 'true' files on nothing.
  fresh_root
  edit "${CQ}" '    outputs:
      has-finding: ${{ steps.count.outputs.has-finding }}
' ''
  run_scenario undeclared-output-fails 1 \
    '.github/workflows/codeql.yml: job notify-finding files on no arm; its gate admits no failure or cancelled result'
  also_expect 'docs/scanners.md:6: codeql.yml/notify-finding files on no arm'
  refute_stderr 'notify-finding has no notify-arms marker'

  # A gate without always() carries the implicit success(), which a
  # failure gate can never meet.
  fresh_root
  edit '.github/workflows/octoscan.yml' \
    "if: always() && github.event_name != 'pull_request' && needs.scan.result == 'failure' && needs.scan.outputs.has-finding == 'true'" \
    "if: github.event_name != 'pull_request' && needs.scan.result == 'failure' && needs.scan.outputs.has-finding == 'true'"
  run_scenario implicit-success-fails 1 \
    'octoscan.yml/notify-finding files on no arm; its gate admits no failure or cancelled result'

  # A renamed job orphans its markers.
  fresh_root
  edit "${CQ}" '  notify-infra:' '  notify-infrastructure:'
  run_scenario renamed-job-fails 1 \
    'docs/scanners.md:7: marker names codeql.yml/notify-infra, which is not a notify-workflow-result job'
  also_expect '.github/workflows/codeql.yml: job notify-infrastructure has no notify-arms marker in the docs'
  also_expect '.github/workflows/codeql.yml (job notify-infrastructure body):1: marker names codeql.yml/notify-infra'

  # --- missing markers ---

  fresh_root
  edit "${DOC}" 'A failed or cancelled zizmor run opens `zizmor-drift` <!-- notify-arms: zizmor-drift-check.yml/notify = failure cancelled -->.' \
    'A failed or cancelled zizmor run opens `zizmor-drift`.'
  run_scenario doc-marker-missing-fails 1 \
    '.github/workflows/zizmor-drift-check.yml: job notify has no notify-arms marker in the docs'

  fresh_root
  edit "${CQ}" "${CQ_INFRA_BODY}" 'An infrastructure failure.'
  run_scenario body-marker-missing-fails 1 \
    '.github/workflows/codeql.yml: job notify-infra has no notify-arms marker in its issue body'

  # A body marker naming another job does not count for its own job.
  fresh_root
  edit "${CQ}" "${CQ_INFRA_BODY}" \
    'An infrastructure failure. <!-- notify-arms: codeql.yml/notify-finding = finding non-pr -->'
  run_scenario body-marker-wrong-job-fails 1 \
    'marker in the body of codeql.yml/notify-infra names codeql.yml/notify-finding'
  also_expect '.github/workflows/codeql.yml: job notify-infra has no notify-arms marker in its issue body'

  # --- malformed markers ---

  fresh_root
  edit "${DOC}" 'codeql.yml/notify-infra = failure cancelled non-pr' 'codeql.yml/notify-infra = failure cancelled nonpr'
  run_scenario unknown-arm-fails 1 'unknown arm "nonpr"'

  fresh_root
  edit "${DOC}" 'codeql.yml/notify-infra = failure cancelled non-pr' 'codeql.yml/notify-infra = failure cancelled cancelled non-pr'
  run_scenario repeated-arm-fails 1 'arm "cancelled" repeated'

  fresh_root
  edit "${DOC}" 'codeql.yml/notify-infra = failure cancelled non-pr' 'codeql.yml/notify-infra failure cancelled non-pr'
  run_scenario malformed-marker-fails 1 'docs/scanners.md:7: malformed notify-arms marker'

  # The scanner set names each workflow file exactly, so a rename is a
  # precondition failure rather than a scanner silently leaving the set.
  fresh_root
  mv -- "${ROOT}/${CQ}" "${ROOT}/.github/workflows/codeql.yaml"
  run_scenario scanner-workflow-renamed-exits-2 2 'missing scanner workflow .github/workflows/codeql.yml'

  fresh_root
  edit "${DOC}" "${CQ_INFRA_DOC}" \
    'and `codeql-infra` <!-- notify-arms: codeql.yml/notify-infra =
failure cancelled non-pr -->.'
  run_scenario marker-spans-lines-fails 1 'docs/scanners.md:7: notify-arms marker spans lines; keep it on one line'

  fresh_root
  edit "${DOC}" "${CQ_INFRA_DOC}" \
    'and `codeql-infra` <!-- notify-arms: codeql.yml/notify-infra = failure cancelled non-pr.'
  run_scenario unclosed-marker-fails 1 'docs/scanners.md:7: unclosed notify-arms marker'

  # At any indent, a comment opening a line starts an HTML block.
  fresh_root
  edit "${DOC}" '`octoscan-infra` <!-- notify-arms' '`octoscan-infra`
    <!-- notify-arms'
  run_scenario marker-opens-line-in-list-fails 1 \
    'docs/scanners.md:13: notify-arms marker opens a line, which cuts it off from its paragraph'

  fresh_root
  edit "${DOC}" "${SC_DOC}" '> A failed or cancelled scorecard run opens `scorecard-drift`
> <!-- notify-arms: scorecard-drift-check.yml/notify = failure cancelled -->.'
  run_scenario marker-opens-line-in-quote-fails 1 \
    'docs/scanners.md:18: notify-arms marker opens a line'

  # --- the cancel word ---

  fresh_root
  edit "${DOC}" "${SC_DOC}" \
    'A failed scorecard run opens `scorecard-drift` <!-- notify-arms: scorecard-drift-check.yml/notify = failure cancelled -->.'
  run_scenario cancel-word-missing-fails 1 \
    'docs/scanners.md:17: marker for scorecard-drift-check.yml/notify declares cancelled, but its paragraph never says so'

  # The word in the next list item is another paragraph.
  fresh_root
  edit "${DOC}" '— no count, or a cancelled job <!-- notify-arms: image-cve-scan.yml/image-cve-scan-trivy-notify-infra' \
    '— no count <!-- notify-arms: image-cve-scan.yml/image-cve-scan-trivy-notify-infra'
  run_scenario cancel-word-next-item-fails 1 \
    'docs/scanners.md:24: marker for image-cve-scan.yml/image-cve-scan-trivy-notify-infra declares cancelled'

  # --- preconditions ---

  fresh_root
  edit '.github/actions/notify-workflow-result/action.yml' "const cancelled = result === 'cancelled';" \
    "const cancelled = result === 'cancelled' || result === 'timed_out';"
  run_scenario composite-changed-exits-2 2 \
    "no longer holds the line \"const cancelled = result === 'cancelled';\""

  fresh_root
  rm -- "${ROOT}/.github/actions/notify-workflow-result/action.yml"
  run_scenario composite-missing-exits-2 2 'missing .github/actions/notify-workflow-result/action.yml'

  fresh_root
  rm -- "${ROOT}/.github/workflows/octoscan.yml"
  run_scenario scanner-workflow-missing-exits-2 2 'missing scanner workflow .github/workflows/octoscan.yml'

  fresh_root
  printf 'name: octoscan\non: push\njobs:\n  scan:\n    runs-on: ubuntu-latest\n    steps:\n      - run: "true"\n' \
    >"${ROOT}/.github/workflows/octoscan.yml"
  run_scenario scanner-without-notify-exits-2 2 \
    'scanner workflow .github/workflows/octoscan.yml has no notify-workflow-result job'

  fresh_root
  printf 'jobs: [unclosed\n' >"${ROOT}/.github/workflows/broken.yml"
  run_scenario unparsable-workflow-exits-2 2 'cannot parse .github/workflows/broken.yml'

  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" "if: always() && github.ref == 'refs/heads/main'"
  run_scenario unsupported-operand-exits-2 2 \
    'job notify-finding: unsupported operand "github.ref" in the if: gate (the watched job is analyze)'

  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" 'if: always() && github.event_name != "pull_request"'
  run_scenario unsupported-text-exits-2 2 'unsupported text ""pull_request"" in the if: gate'

  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" "if: always() && (needs.analyze.result == 'failure'"
  run_scenario unbalanced-parens-exits-2 2 'unbalanced parentheses in the if: gate'

  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" "if: always() 'x'"
  run_scenario trailing-text-exits-2 2 "trailing text \"'x'\" in the if: gate"

  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" "if: always() && 'a' == always()"
  run_scenario non-string-compare-exits-2 2 'comparison of a non-string in the if: gate'

  fresh_root
  edit "${SC}" 'needs: drift-check' 'needs: [drift-check, other]'
  run_scenario multi-needs-exits-2 2 'job notify: needs: does not name exactly one job'

  fresh_root
  edit "${SC}" 'result: ${{ needs.drift-check.result }}' 'result: ${{ needs.drift-check.outputs.result || needs.drift-check.result }}'
  run_scenario unsupported-result-exits-2 2 'unsupported result: input'

  # A scanner job is derived even when it has no marker at all, so an
  # unreadable gate stops the run instead of hiding behind the gap.
  fresh_root
  edit "${CQ}" "${CQ_FINDING_GATE}" "if: always() && github.actor == 'someone'"
  edit "${CQ}" 'A finding. <!-- notify-arms: codeql.yml/notify-finding = finding non-pr -->' 'A finding.'
  edit "${DOC}" '`codeql-critical` <!-- notify-arms: codeql.yml/notify-finding = finding non-pr -->' '`codeql-critical`'
  run_scenario unmarked-unreadable-gate-exits-2 2 'unsupported operand "github.actor"'

  # A non-scanner job outside the grammar is derived once a marker names it.
  fresh_root
  printf 'Other <!-- notify-arms: other.yml/notify = failure -->.\n' >>"${ROOT}/${DOC}"
  run_scenario named-unreadable-gate-exits-2 2 'job notify: needs: does not name exactly one job'

  fresh_root
  printf '```text\nopen fence\n' >>"${ROOT}/${DOC}"
  run_scenario unterminated-fence-exits-2 2 'docs/scanners.md: unterminated code fence'

  fresh_root
  printf '<!-- open comment\n' >>"${ROOT}/${DOC}"
  run_scenario unterminated-comment-exits-2 2 'docs/scanners.md:33: unterminated HTML comment'

  fresh_root
  rm -- "${ROOT}/${DOC}"
  run_scenario empty-doc-scan-exits-2 2 'enumerated 0 files via list prose'

  # Outside a git repository, the scan set cannot be listed.
  ROOT="$(mktemp --directory)"
  cp --recursive -- "${BASE}/." "${ROOT}/"
  run_scenario not-a-repository-exits-2 2 'list prose failed enumerating the scan set'

  harness_assert_verify
  if ((failures)); then
    printf '%d scenario(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all scenarios passed\n'
}

main "$@"
