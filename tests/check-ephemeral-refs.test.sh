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
# have covered rather than repeating the format string six times.
# @arg $1 sources scanned  @arg $2 lines read  @arg $3 allowlisted skipped
# @arg $4 code-fence lines  @arg $5 inline code spans
# @arg $6 generated-block lines
function summary() {
  printf 'ephemeral-refs: scanned %d source(s), %d line(s); skipped %d allowlisted; exempted %d code-fence line(s), %d inline code span(s), %d generated-block line(s)' \
    "$1" "$2" "$3" "$4" "$5" "$6"
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
  expected_stdout="$(summary 2 6 1 0 0 0)"
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

# @description Assert that banned shapes inside a tilde (`~~~`) code
# fence are stripped. The fixture is built at runtime in a temp dir so
# the Markdown formatter cannot normalize the tilde fence to backticks.
function run_tilde_scenario() {
  local tmp_root
  tmp_root="$(mktemp -d)"
  mkdir -p "${tmp_root}/docs"
  printf '# t\n\n~~~\nref #123 on 2026-06-18 Phase 2 (D3) .claude/x.md\n~~~\n' \
    >"${tmp_root}/docs/tilde.md"

  local actual_exit=0
  EPHEMERAL_REFS_ROOT_OVERRIDE="${tmp_root}" \
    EPHEMERAL_REFS_SOURCES_OVERRIDE='docs/tilde.md' \
    "${SCRIPT}" >/dev/null 2>&1 || actual_exit=$?

  if [[ ${actual_exit} -ne 0 ]]; then
    printf 'FAIL: tilde-fenced banned shapes pass — expected exit 0, got %d\n' \
      "${actual_exit}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: tilde-fenced banned shapes pass (exit 0)\n'
  fi

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

function main() {
  # A clean run is silent about its findings by construction, so every
  # scenario asserts the scope summary too: how much prose the scan
  # actually read, and how much of it was exempted as code or generated
  # output. That is what separates a doc the lint found clean from a doc
  # the lint mostly skipped.
  run_scenario 'good prose passes' 'good' 'source.md' '' 0 '' \
    "$(summary 1 10 0 0 2 0)"
  run_scenario 'bare issue ref fails' \
    'bad-issue-ref' 'source.md' '' 1 'source.md:3: [issue-ref] #123' \
    "$(summary 1 3 0 0 0 0)"
  run_scenario 'prose date fails' \
    'bad-date' 'source.md' '' 1 '[date]' "$(summary 1 3 0 0 0 0)"
  run_scenario 'planning label fails' \
    'bad-planning' 'source.md' '' 1 '[planning]' "$(summary 1 3 0 0 0 0)"
  run_scenario 'review-pass label fails' \
    'bad-review' 'source.md' '' 1 '[review]' "$(summary 1 3 0 0 0 0)"
  # Enumerated shapes that legitimately start a match must still report.
  run_scenario 'standalone planning shapes still match' \
    'planning-shapes' 'source.md' '' 1 '[planning]' "$(summary 1 5 0 0 0 0)"
  run_scenario 'standalone review shapes still match' \
    'review-shapes' 'source.md' '' 1 '[review]' "$(summary 1 5 0 0 0 0)"
  # Mid-word matches (UTF-8 -> F-8, ID5: -> D5:) must not be smuggled
  # back into the blocking gate by the bare planning/review shapes.
  run_scenario 'encoding shapes are not planning/review labels' \
    'false-positive-shapes' 'source.md' '' 0 '' "$(summary 1 5 0 0 0 0)"
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
    "$(summary 1 5 0 0 1 0)"
  run_scenario 'fenced BEGIN/END mention does not open a block' \
    'fenced-begin-mention' 'source.md' '' 1 'source.md:11: [issue-ref] #789' \
    "$(summary 1 11 0 5 0 0)"
  run_scenario 'literal .claude path fails' \
    'bad-claude-path' 'source.md' '' 1 '[claude-path]' "$(summary 1 3 0 0 0 0)"
  run_scenario 'code-span/block banned shapes pass' \
    'exempt-codeblock' 'source.md' '' 0 '' "$(summary 1 10 0 4 2 0)"
  run_scenario 'generated-block banned shapes pass' \
    'exempt-genblock' 'source.md' '' 0 '' "$(summary 1 9 0 0 0 5)"
  run_scope_scenario
  run_tilde_scenario
  run_scenario 'causal phrase passes blocking pass' \
    'advisory' 'source.md' '' 0 '' "$(summary 1 3 0 0 0 0)"
  run_scenario 'causal phrase prints in advisory mode' \
    'advisory' 'source.md' '--advisory' 0 '[advisory]' "$(summary 1 3 0 0 0 0)"

  harness_assert_verify || failures=$((failures + 1))

  if [[ ${failures} -gt 0 ]]; then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
