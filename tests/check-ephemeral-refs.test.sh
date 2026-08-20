#!/usr/bin/env bash
# tests/check-ephemeral-refs.test.sh

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-ephemeral-refs.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-ephemeral-refs"

failures=0

# @description Render the scope summary the lint prints on stdout, so a
# scenario states the sources and exempt regions it expects the run to
# have covered rather than repeating the format string once per scenario.
# Shell and Nix comments are counted separately, never summed: the two
# corpora differ by an order of magnitude in the live tree, so a shared
# total would stay positive with one extractor matching nothing at all.
# The parsed/pre-filtered split is stated separately from the source
# counts because a source the candidate pass sets aside contributes no
# lines, comments or exempt regions — a scenario that named only the
# source count could not tell a file that was read from one that was
# skipped.
# @arg $1 markdown sources  @arg $2 shell sources  @arg $3 nix sources
# @arg $4 yaml sources  @arg $5 candidates parsed
# @arg $6 sources pre-filtered  @arg $7 lines read
# @arg $8 shell comments  @arg $9 nix comments  @arg ${10} yaml comments
# @arg ${11} allowlisted skipped  @arg ${12} code-fence lines
# @arg ${13} inline code spans  @arg ${14} generated-block lines
function summary() {
  printf 'ephemeral-refs: scanned %d markdown, %d shell, %d nix, %d yaml source(s); parsed %d candidate(s), pre-filtered %d; %d line(s), %d shell comment(s), %d nix comment(s), %d yaml comment(s); skipped %d allowlisted; exempted %d code-fence line(s), %d inline code span(s), %d generated-block line(s)' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" \
    "${13}" "${14}"
}

# @description Run the lint against one source under an arbitrary repo
# root and assert its exit code, a stderr substring, and the scope
# summary it prints on stdout.
# @arg $1 name human-readable scenario name
# @arg $2 root absolute path used as REPO_ROOT for the run
# @arg $3 source_rel source file relative to root
# @arg $4 mode extra flag passed to the script (empty or "--advisory")
# @arg $5 expected_exit expected exit status
# @arg $6 expected_stderr stderr substring that must be present (empty to skip)
# @arg $7 expected_stdout stdout substring that must be present (empty to skip)
function run_scenario_root() {
  local -r name="$1"
  local -r root="$2"
  local -r source_rel="$3"
  local -r mode="$4"
  local -r expected_exit="$5"
  local -r expected_stderr="$6"
  local -r expected_stdout="${7:-}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local -a args=()
  [[ -n ${mode} ]] && args+=("${mode}")

  local actual_exit=0
  EPHEMERAL_REFS_ROOT_OVERRIDE="${root}" \
    EPHEMERAL_REFS_SOURCES_OVERRIDE="${source_rel}" \
    "${SCRIPT}" "${args[@]}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stdout} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
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
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# @description Run the lint against one checked-in fixture directory.
# @arg $1 name human-readable scenario name
# @arg $2 fixture_dir fixture directory under FIXTURES (used as REPO_ROOT)
# @arg $3 source_rel source file relative to the fixture REPO_ROOT
# @arg $4 mode extra flag passed to the script (empty or "--advisory")
# @arg $5 expected_exit expected exit status
# @arg $6 expected_stderr stderr substring that must be present (empty to skip)
# @arg $7 expected_stdout stdout substring that must be present (empty to skip)
function run_scenario() {
  run_scenario_root "$1" "${FIXTURES}/$2" "$3" "$4" "$5" "$6" "${7:-}"
}

# @description Assert that the source enumeration reaches Markdown
# outside `README.md` and `docs/`, and that `.claude/` prose stays
# allowlisted. Deliberately omits EPHEMERAL_REFS_SOURCES_OVERRIDE: that
# variable short-circuits the enumeration this scenario is about, so
# only the root override may be set. The `.claude/` fixture file sits
# under `commands/` because contributor ignore rules commonly exclude
# direct children of `.claude/`, and an ignored file is neither
# committable nor enumerable.
function run_scope_scenario() {
  local -r name='enumeration reaches SECURITY.md and skips .claude'
  local -r expected_stderr='SECURITY.md:3: [issue-ref] #456'
  local expected_stdout
  expected_stdout="$(summary 2 0 0 0 1 1 3 0 0 0 1 0 0 0)"
  readonly expected_stdout

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  EPHEMERAL_REFS_ROOT_OVERRIDE="${FIXTURES}/scope" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne 1 ]]; then
    printf 'FAIL: %s — expected exit 1, got %d\n' "${name}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif grep --fixed-strings --quiet -- 'notes.md' "${stderr_file}"; then
    printf 'FAIL: %s — .claude prose was scanned\n' "${name}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  harness_assert_also "${expected_stdout}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# @description Run the advisory pass over one fixture and assert the
# exact set of advisory lines it reports. Substring presence alone
# cannot state the absence a precision scenario is about, and the scope
# summary carries no advisory tally, so the count of `[advisory]` lines
# is asserted alongside each expected line: a fixture that is supposed
# to report nothing proves it by reporting zero, and one that reports
# six proves no seventh phrase crept in.
# @arg $1 name human-readable scenario name
# @arg $2 fixture_dir fixture directory under FIXTURES
# @arg $3 expected_stdout scope summary the run must print
# @arg $@ (from $4) every `[advisory] file:line: phrase` line expected,
#   in any order; none for a fixture that must stay silent
function run_advisory_scenario() {
  local -r name="$1"
  local -r fixture_dir="$2"
  local -r expected_stdout="$3"
  shift 3
  local -a expected_lines=("$@")

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  EPHEMERAL_REFS_ROOT_OVERRIDE="${FIXTURES}/${fixture_dir}" \
    EPHEMERAL_REFS_SOURCES_OVERRIDE='source.md' \
    "${SCRIPT}" --advisory >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  local actual_count
  actual_count="$(grep --count --fixed-strings -- '[advisory] ' "${stderr_file}" || true)"

  local missing=''
  local line
  for line in ${expected_lines+"${expected_lines[@]}"}; do
    if ! grep --fixed-strings --quiet -- "${line}" "${stderr_file}"; then
      missing="${line}"
      break
    fi
  done

  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: %s — expected exit 0, got %d\n' "${name}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ ${actual_count} -ne ${#expected_lines[@]} ]]; then
    printf 'FAIL: %s — expected %d advisory line(s), got %d\n' \
      "${name}" "${#expected_lines[@]}" "${actual_count}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${missing} ]]; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${missing}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stdout}" "${stdout_file}"; then
    printf 'FAIL: %s — stdout missing %q\n' "${name}" "${expected_stdout}" >&2
    cat -- "${stdout_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_lines[0]-}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  local extra
  for extra in ${expected_lines+"${expected_lines[@]:1}"}; do
    harness_assert_also "${extra}"
  done
  harness_assert_also "${expected_stdout}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# @description Assert that banned shapes inside a tilde (`~~~`) code
# fence are stripped. The fixture is built at runtime in a temp dir so
# the Markdown formatter cannot normalize the tilde fence to backticks.
# The scope summary carries the assertion that makes a clean exit mean
# something: three fence lines exempted out of five read. Without it a
# run that stopped opening the file at all would score the same verdict.
function run_tilde_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/docs"
  printf '# t\n\n~~~\nref #123 on 2026-06-18 Phase 2 (D3) .claude/x.md\n~~~\n' \
    >"${tmp_root}/docs/tilde.md"

  run_scenario_root 'tilde-fenced banned shapes pass' "${tmp_root}" \
    'docs/tilde.md' '' 0 '' "$(summary 1 0 0 0 1 0 5 0 0 0 0 3 0 0)"

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that an opening code fence with no closing fence
# fails loud rather than blanking every line below it — the same
# end-of-input treatment an unterminated generated block gets. The
# fixture is built at runtime in a temp dir because the Markdown
# formatter closes a dangling fence, which is the exact shape under test.
function run_unterminated_fence_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/docs"
  printf '# t\n\n```\ncode\n\nA blocking ref #321 sits below an unclosed fence.\n' \
    >"${tmp_root}/docs/unclosed.md"

  run_scenario_root 'unterminated code fence errors' "${tmp_root}" \
    'docs/unclosed.md' '' 1 'unterminated code fence'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that a source `shfmt` cannot parse is a
# could-not-run rather than a clean read. Built at runtime: a broken
# script committed under `tests/fixtures/` would fail the formatter and
# the shell-hygiene lints that scan the fixture trees.
function run_unparsable_shell_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/scripts"
  printf '#!/usr/bin/env bash\n# ref #123 below a broken construct\nif [[ -f x ]; then\n' \
    >"${tmp_root}/scripts/broken.sh"

  run_scenario_root 'unparsable shell source is a could-not-run' \
    "${tmp_root}" 'scripts/broken.sh' '' 2 'could not parse this file as shell'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that a source the candidate pass sets aside is
# reported as set aside rather than as read. The broken construct below
# is the same one the scenario above uses, minus the token that made
# that file a candidate — so `shfmt` never sees it, the parse failure
# goes unreported, and the run exits 0. That is the diagnostic the
# candidate pass deliberately gives up: a source carrying no candidate
# token has no violation to hide, and the formatter and `shellcheck`
# already gate shell parsability. Pinned here so the trade is a stated
# behavior rather than an accident nobody would notice.
function run_prefiltered_shell_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/scripts"
  printf '#!/usr/bin/env bash\n# a comment below a broken construct\nif [[ -f x ]; then\n' \
    >"${tmp_root}/scripts/quiet.sh"

  run_scenario_root 'unparsable shell with no candidate token is set aside' \
    "${tmp_root}" 'scripts/quiet.sh' '' 0 '' "$(summary 0 1 0 0 0 1 0 0 0 0 0 0 0 0)"

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that a shell source set yielding zero comments
# exits 2 rather than reporting a clean tree: a gate that reads nothing
# has stopped reading, which a clean exit code cannot distinguish from a
# gate that read everything and found nothing. The token sits in a
# string rather than a comment, which is what the assertion needs: the
# source must reach the extractor — so it has to be a candidate — and
# still yield nothing for it to read.
function run_no_comments_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/scripts"
  printf "printf '%%s\\\\n' 'ref #123 sits in a string'\necho world\n" \
    >"${tmp_root}/scripts/bare.sh"

  run_scenario_root 'shell source set with no comments is a could-not-run' \
    "${tmp_root}" 'scripts/bare.sh' '' 2 'no comments extracted from 1 shell source(s)'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert the structural pass reads a Markdown source the
# candidate pass set aside. An unterminated fence blanks every line
# below it, so it must stay a named defect in a file the scan never
# opens — otherwise the malformed-doc diagnostic would apply only to
# docs that happen to carry a banned token.
function run_prefiltered_fence_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/docs"
  printf '# t\n\n```\ncode\n\nClean prose sits below an unclosed fence.\n' \
    >"${tmp_root}/docs/quiet-unclosed.md"

  run_scenario_root 'unterminated fence errors with no candidate token' \
    "${tmp_root}" 'docs/quiet-unclosed.md' '' 1 'unterminated code fence'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert the structural pass reads a Nix source the
# candidate pass set aside, for the reason the Markdown one gets the
# same treatment: an unterminated block comment leaves every line below
# the opener claimed as comment text.
function run_prefiltered_nix_block_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/nix"
  printf '{\n  /* an opener that never closes\n  enable = true;\n}\n' \
    >"${tmp_root}/nix/quiet-unclosed.nix"

  run_scenario_root 'unterminated nix block errors with no candidate token' \
    "${tmp_root}" 'nix/quiet-unclosed.nix' '' 1 'unterminated Nix block comment'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that a temp area the lint cannot write is a
# could-not-run rather than a finding. Every source the scan reads is
# staged through a temp file, and an unguarded assignment from `mktemp`
# under `set -Eeuo pipefail` kills the run with mktemp's own status 1 —
# the code that means "this file carries a banned reference". A hook
# reading that sends the operator to edit prose the scan never opened.
# TMPDIR is set on the lint's own environment only, so the harness keeps
# a working temp area for the capture files below.
function run_unwritable_tmpdir_scenario() {
  local -r name='unwritable TMPDIR is a could-not-run'
  local -r expected_stderr='cannot create a temp file (TMPDIR=/nonexistent-temp-root-probe)'

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  TMPDIR='/nonexistent-temp-root-probe' \
    EPHEMERAL_REFS_ROOT_OVERRIDE="${FIXTURES}/good" \
    EPHEMERAL_REFS_SOURCES_OVERRIDE='source.md' \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne 2 ]]; then
    printf 'FAIL: %s — expected exit 2, got %d\n' "${name}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# @description Assert that the breadth rule holds each language to its
# own corpus. A Nix source set yielding zero comments must exit 2 on the
# strength of the Nix tally alone — a joint shell+Nix total lets the
# repo's far larger shell corpus satisfy the assertion for a Nix
# extractor that has stopped matching anything.
function run_nix_no_comments_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/nix"
  # The token sits in a string attribute, not a comment: the source has
  # to reach the extractor to prove the extractor found nothing.
  printf '{\n  ref = "#123";\n}\n' >"${tmp_root}/nix/bare.nix"

  run_scenario_root 'nix source set with no comments is a could-not-run' \
    "${tmp_root}" 'nix/bare.nix' '' 2 'no comments extracted from 1 nix source(s)'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that a Nix block comment with no closing delimiter
# fails loud. The extractor has no way back out of the block, so every
# line below the opener is handed on as comment text and the run reports
# against code — the header literal below surfaces as a prose date. Built
# at runtime: an unclosed `/*` is not valid Nix, so a committed fixture
# would fail the formatter.
function run_unterminated_nix_block_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/nix"
  printf '{\n  /* an opener that never closes\n  header = "X-GitHub-Api-Version: 2022-11-28";\n}\n' \
    >"${tmp_root}/nix/unclosed.nix"

  run_scenario_root 'unterminated nix block comment errors' "${tmp_root}" \
    'nix/unclosed.nix' '' 1 'unterminated Nix block comment'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert the breadth rule holds YAML to its own corpus,
# the same way it holds shell and Nix to theirs. The token sits in a
# quoted scalar so the source is a candidate and reaches the extractor;
# what it must not have is a comment for the extractor to find.
function run_yaml_no_comments_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir --parents "${tmp_root}/.github"
  printf 'name: quiet\nenv:\n  ANCHOR: "#123"\n' \
    >"${tmp_root}/.github/bare.yml"

  run_scenario_root 'yaml source set with no comments is a could-not-run' \
    "${tmp_root}" '.github/bare.yml' '' 2 'no comments extracted from 1 yaml source(s)'

  rm --recursive --force -- "${tmp_root}"
}

# @description Assert that a comment-free shell source still contributes
# its line count. The extractor pairs a comment-row file against the
# source with `awk`'s two-operand `NR == FNR` split, and an empty row
# file collapses that split — the source's own lines are mistaken for
# comment rows and nothing is emitted, so the file reads as blank while
# the run still exits 0. Pairing a commented source with a comment-free
# one and asserting the combined line total is what observes that: the
# verdict is clean either way, only the tally moves.
function run_source_pair_scenario() {
  run_scenario_root 'comment-free shell source still contributes its lines' \
    "${FIXTURES}/shell-pair" $'commented.sh\nbare.sh' '' 0 '' \
    "$(summary 0 2 0 0 2 0 6 1 0 0 0 0 1 0)"
}

function main() {
  # A clean run is silent about its findings by construction, so every
  # scenario asserts the scope summary too: how much prose the scan
  # actually read, and how much of it was exempted as code or generated
  # output. That is what separates a doc the lint found clean from a doc
  # the lint mostly skipped.
  run_scenario 'good prose passes' 'good' 'source.md' '' 0 '' \
    "$(summary 1 0 0 0 1 0 10 0 0 0 0 0 2 0)"
  run_scenario 'bare issue ref fails' \
    'bad-issue-ref' 'source.md' '' 1 'source.md:3: [issue-ref] #123' \
    "$(summary 1 0 0 0 1 0 3 0 0 0 0 0 0 0)"
  run_scenario 'prose date fails' \
    'bad-date' 'source.md' '' 1 '[date]' "$(summary 1 0 0 0 1 0 3 0 0 0 0 0 0 0)"
  run_scenario 'planning label fails' \
    'bad-planning' 'source.md' '' 1 '[planning]' "$(summary 1 0 0 0 1 0 3 0 0 0 0 0 0 0)"
  run_scenario 'review-pass label fails' \
    'bad-review' 'source.md' '' 1 '[review]' "$(summary 1 0 0 0 1 0 3 0 0 0 0 0 0 0)"
  # Enumerated shapes that legitimately start a match must still report.
  run_scenario 'standalone planning shapes still match' \
    'planning-shapes' 'source.md' '' 1 '[planning]' "$(summary 1 0 0 0 1 0 5 0 0 0 0 0 0 0)"
  run_scenario 'standalone review shapes still match' \
    'review-shapes' 'source.md' '' 1 '[review]' "$(summary 1 0 0 0 1 0 5 0 0 0 0 0 0 0)"
  # Mid-word matches (`UTF-8` -> `F-8`, `ID5:` -> `D5:`) must not be smuggled
  # back into the blocking gate by the bare planning/review shapes.
  run_scenario 'encoding shapes are not planning/review labels' \
    'false-positive-shapes' 'source.md' '' 0 '' "$(summary 1 0 0 0 1 0 8 0 0 0 0 0 1 0)"
  # An unterminated generated block must fail loud, not blank to EOF.
  # The run aborts mid-scan, so no scope summary is owed.
  run_scenario 'unterminated generated block errors' \
    'bad-unterminated-genblock' 'source.md' '' 1 'unterminated generated block'
  # An unterminated code fence gets the same treatment: exempting every
  # line below it must be an error, not a silent pass.
  run_unterminated_fence_scenario
  # A BEGIN marker a doc quotes in prose is documentation, not a block
  # opener: the violation below it must still report, and no
  # unterminated-block error may fire. The summary backs that up — the
  # quoted marker is counted as a code span, never as a generated block.
  run_scenario 'inline BEGIN mention does not open a block' \
    'inline-begin-mention' 'source.md' '' 1 'source.md:5: [issue-ref] #654' \
    "$(summary 1 0 0 0 1 0 5 0 0 0 0 0 1 0)"
  run_scenario 'fenced BEGIN/END mention does not open a block' \
    'fenced-begin-mention' 'source.md' '' 1 'source.md:11: [issue-ref] #789' \
    "$(summary 1 0 0 0 1 0 11 0 0 0 0 5 0 0)"
  run_scenario 'literal .claude path fails' \
    'bad-claude-path' 'source.md' '' 1 '[claude-path]' "$(summary 1 0 0 0 1 0 3 0 0 0 0 0 0 0)"
  run_scenario 'code-span/block banned shapes pass' \
    'exempt-codeblock' 'source.md' '' 0 '' "$(summary 1 0 0 0 1 0 10 0 0 0 0 4 2 0)"
  run_scenario 'generated-block banned shapes pass' \
    'exempt-genblock' 'source.md' '' 0 '' "$(summary 1 0 0 0 1 0 9 0 0 0 0 0 0 5)"
  run_scope_scenario
  run_tilde_scenario
  run_scenario 'causal phrase passes blocking pass' \
    'advisory' 'source.md' '' 0 '' "$(summary 1 0 0 0 1 0 6 0 0 0 0 0 1 0)"
  run_scenario 'causal phrase prints in advisory mode' \
    'advisory' 'source.md' '--advisory' 0 '[advisory] source.md:3:' \
    "$(summary 1 0 0 0 1 0 6 0 0 0 0 0 1 0)"
  # Precision, both directions. Every retained alternative names a past
  # state outright, so it must still fire; the shapes below it are bare
  # verbs and prepositions whose reading depends on their subject, so
  # they must not. The unjudgeable fixture carries a quoted `previously`
  # to stay in the advisory candidate set: without it the union would
  # set the file aside and a silent run would prove nothing about what
  # the scan does with the prose.
  run_advisory_scenario 'every retained causal phrase reports' \
    'causal-retained' "$(summary 1 0 0 0 1 0 15 0 0 0 0 0 0 0)" \
    '[advisory] source.md:5: Migration note' \
    '[advisory] source.md:7: Tightened from' \
    '[advisory] source.md:9: switched from' \
    '[advisory] source.md:11: legacy wrapper was deleted' \
    '[advisory] source.md:13: added in 42' \
    '[advisory] source.md:15: post-PR 7'
  run_advisory_scenario 'threat and drift prose reports nothing' \
    'causal-unjudgeable' "$(summary 1 0 0 0 1 0 12 0 0 0 0 0 1 0)"

  # Shell sources reach the same class regexes through a comment
  # extractor rather than through `strip_exempt`, so each scenario below
  # states both the verdict and the comment count behind it: a verdict
  # backed by zero comments is a gate that stopped reading.
  run_scenario 'shell comment blocking ref fails' \
    'shell-blocking' 'source.sh' '' 1 'source.sh:3: [issue-ref] #123' \
    "$(summary 0 1 0 0 1 0 4 2 0 0 0 0 0 0)"
  run_scenario 'shell comment causal phrase passes blocking pass' \
    'shell-causal' 'source.sh' '' 0 '' "$(summary 0 1 0 0 1 0 4 2 0 0 0 0 1 0)"
  run_scenario 'shell comment causal phrase prints in advisory mode' \
    'shell-causal' 'source.sh' '--advisory' 0 '[advisory] source.sh:2:' \
    "$(summary 0 1 0 0 1 0 4 2 0 0 0 0 1 0)"
  # The two false-positive guards below pass against the pre-widening
  # lint as well; they exist to hold the AST extractor to its promise
  # that a hash inside code is not a comment, not to prove the widening.
  run_scenario 'shell string literals are not comments' \
    'shell-literal' 'source.sh' '' 0 '' "$(summary 0 1 0 0 1 0 5 1 0 0 0 0 0 0)"
  run_scenario 'shell heredoc body is not comments' \
    'shell-heredoc' 'source.sh' '' 0 '' "$(summary 0 1 0 0 1 0 7 1 0 0 0 0 0 0)"
  run_scenario 'shell trailing comment is scanned' \
    'shell-trailing' 'source.sh' '' 1 'source.sh:3: [issue-ref] #321' \
    "$(summary 0 1 0 0 1 0 3 2 0 0 0 0 0 0)"
  run_scenario 'shell comment code spans are exempt' \
    'shell-backtick' 'source.sh' '' 0 '' "$(summary 0 1 0 0 1 0 3 1 0 0 0 0 5 0)"
  # Only the comment opening line 1 at column 1 is the shebang. A comment
  # whose text happens to start with `!` is prose wherever else it sits,
  # so the ref on line 3 must report and the comment tally must count it.
  run_scenario 'bang-prefixed comment below the shebang is scanned' \
    'shell-bang-comment' 'source.sh' '' 1 'source.sh:3: [issue-ref] #234' \
    "$(summary 0 1 0 0 1 0 4 2 0 0 0 0 0 0)"
  # `shfmt` strips the hash from a comment's text. Put back, or a
  # reference written flush against it is invisible to the class regexes.
  run_scenario 'shell ref flush against the hash is scanned' \
    'shell-hash-flush' 'source.sh' '' 1 'source.sh:2: [issue-ref] #345' \
    "$(summary 0 1 0 0 1 0 3 1 0 0 0 0 0 0)"
  run_unparsable_shell_scenario
  run_prefiltered_shell_scenario
  run_no_comments_scenario
  run_source_pair_scenario
  run_unwritable_tmpdir_scenario
  # The structural pass answers for the sources the candidate pass sets
  # aside; without these two the malformed-doc diagnostics would only
  # ever be proved on files that happen to carry a banned token.
  run_prefiltered_fence_scenario
  run_prefiltered_nix_block_scenario

  # Nix sources reach the same class regexes through a line-start comment
  # matcher covering both comment forms. The embedded-shell scenario is
  # the one that keeps the shell in a Nix string block in scope: its
  # comment sits inside `''…''`, and a matcher that stopped at the string
  # boundary would report the file clean.
  run_scenario 'nix comment blocking ref fails' \
    'nix-comment' 'source.nix' '' 1 'source.nix:2: [issue-ref] #123' \
    "$(summary 0 0 1 0 1 0 4 0 1 0 0 0 0 0)"
  run_scenario 'nix embedded shell comment is scanned' \
    'nix-embedded-shell' 'source.nix' '' 1 'source.nix:4: [issue-ref] #456' \
    "$(summary 0 0 1 0 1 0 7 0 1 0 0 0 0 0)"
  # The Nix matcher strips only the indent, so a ref flush against the
  # hash reaches the class regexes the same way it does on the shell path.
  run_scenario 'nix ref flush against the hash is scanned' \
    'nix-hash-flush' 'source.nix' '' 1 'source.nix:2: [issue-ref] #456' \
    "$(summary 0 0 1 0 1 0 4 0 1 0 0 0 0 0)"
  # `/* */` is the other Nix comment form. Nothing forbids one, so a
  # matcher that read only `#` lines would leave it as an open evasion
  # path — the tally states all four lines the block spans were read.
  run_scenario 'nix block comment blocking ref fails' \
    'nix-block-comment' 'source.nix' '' 1 'source.nix:3: [issue-ref] #789' \
    "$(summary 0 0 1 0 1 0 7 0 4 0 0 0 0 0)"
  run_unterminated_nix_block_scenario
  run_nix_no_comments_scenario

  # YAML reaches the same class regexes through a line-start comment
  # matcher, the shape the Nix path uses and for the same reason: no
  # comment-preserving reader in this toolchain can tell a trailing `#`
  # from one inside a quoted scalar.
  run_scenario 'yaml comment blocking ref fails' \
    'yaml-comment' 'source.yml' '' 1 'source.yml:3: [issue-ref] #123' \
    "$(summary 0 0 0 1 1 0 5 0 0 1 0 0 0 0)"
  # The population a YAML parser cannot reach: to one, a `run:` block is
  # a single string, so a comment-node reader sees nothing here at all.
  # A third of this repo's YAML comments live in blocks like this one.
  run_scenario 'yaml block-scalar comment is scanned' \
    'yaml-block-scalar' 'source.yml' '' 1 'source.yml:12: [issue-ref] #456' \
    "$(summary 0 0 0 1 1 0 13 0 0 1 0 0 0 0)"
  # False-positive guards. Both pass against the pre-widening lint too —
  # they hold the matcher to its promise that only a line-start `#`
  # opens a comment, rather than proving the widening.
  run_scenario 'yaml quoted and trailing hashes are not comments' \
    'yaml-quoted-hash' 'source.yml' '' 0 '' \
    "$(summary 0 0 0 1 1 0 10 0 0 2 0 0 0 0)"
  run_scenario 'yaml comment code spans are exempt' \
    'yaml-backtick' 'source.yml' '' 0 '' \
    "$(summary 0 0 0 1 1 0 5 0 0 1 0 0 1 0)"
  run_yaml_no_comments_scenario

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
