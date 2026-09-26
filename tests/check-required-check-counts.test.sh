#!/usr/bin/env bash
# tests/check-required-check-counts.test.sh
#
# Failure-mode harness for scripts/check-required-check-counts.sh.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-required-check-counts.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-required-check-counts"

failures=0

# The stderr of the most recent scenario, kept so `also_expect` can pin a
# second finding to stderr.
LAST_STDERR=''
LAST_NAME=''

# @description Run the script against a scenario root; assert exit code,
# stderr, and — on the clean path — the summary line. The summary carries
# the declared-count tally and the scan breadth, which is what tells the
# clean scenarios apart: a pass with no declared count read says nothing
# about whether the markers were parsed.
#
# @arg $1 scenario name (a directory under FIXTURES/ unless $5 is given)
# @arg $2 expected exit code (0, 1, or 2)
# @arg $3 expected stderr substring (empty string skips the check)
# @arg $4 expected stdout substring (empty string skips the check)
# @arg $5 scenario root override (defaults to FIXTURES/<name>)
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expected_stderr="$3"
  local -r expected_stdout="${4:-}"
  local -r root="${5:-${FIXTURES}/${name}}"

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  SCAN_ROOT_OVERRIDE="${root}" \
    "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
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

# @description Make a scratch scenario root: its own git repository holding
# the clean scenario's three-row table. Used for inputs the formatter would
# repair if checked in as fixtures, and for untracked files, which a
# committed fixture cannot be.
# @stdout the new root
function scratch_root() {
  local root
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs/security"
  git -C "${root}" init --quiet
  # The caller's global excludes would otherwise decide what is untracked.
  git -C "${root}" config core.excludesFile /dev/null
  cp -- "${FIXTURES}/clean-passes/docs/security/required-checks.md" \
    "${root}/docs/security/required-checks.md"
  printf '%s\n' "${root}"
}

function main() {
  # --- declared counts ---

  # The clean tree holds one declared count and near-misses the backstop
  # must not read as a count: a subset count phrased another way, a time
  # before "required checks", a count after the noun, a count three words
  # before it, a number word ending another word ("Someone"), a noun
  # continuing into a longer word ("contextual"), and a second table under
  # a later heading that must not lift the row total to four.
  run_scenario 'clean-passes' 0 '' \
    '1 declared count(s) match 3 required context(s); scanned 2 file(s), 21 prose line(s)'

  # The whole diagnostic is asserted: the stated number, the table's
  # number, and the line the marker sits on rather than the paragraph's
  # first line.
  run_scenario 'mismatch-fails' 1 \
    'docs/x.md:5: states 4 required contexts; docs/security/required-checks.md has 3'

  # A paragraph with two markers is judged per marker, and the second one's
  # finding names its own line.
  run_scenario 'second-marker-line-fails' 1 \
    'docs/x.md:5: states 2 required contexts; docs/security/required-checks.md has 3'

  # The claim is the number directly before the marker, so a paragraph that
  # also states a subset count in words passes.
  run_scenario 'two-numbers-passes' 0 '' \
    '1 declared count(s) match 3 required context(s); scanned 2 file(s), 15 prose line(s)'

  # A marker that resolves to no digit count is a finding, not a skip.
  run_scenario 'word-marker-fails' 1 \
    'docs/x.md:3: count marker follows "three", not a number written in digits'
  # A marker after punctuation has no number to read.
  run_scenario 'no-number-marker-fails' 1 \
    'docs/x.md:3: count marker follows "is:", not a number written in digits'
  # A digit run glued to a letter is not a count.
  run_scenario 'attached-letter-fails' 1 \
    'docs/x.md:3: count marker follows "v3", not a number written in digits'
  run_scenario 'unknown-key-fails' 1 \
    'docs/x.md:3: unknown count marker key "required-checks"'

  # --- undeclared counts: the backstop ---

  # Every undeclared count in a paragraph is reported, not only the first.
  run_scenario 'undeclared-fails' 1 \
    'docs/x.md:3: undeclared required-check count "3 required checks"'
  also_expect 'docs/x.md:3: undeclared required-check count "5 required contexts"'
  # Lowercased before matching, so a sentence-initial number word counts.
  run_scenario 'word-undeclared-fails' 1 \
    'docs/x.md:3: undeclared required-check count "Three required status checks"'
  # Lines are joined per paragraph, so a count wrapped mid-phrase is one
  # phrase, quoted on one line. The finding names the number's line even
  # when the number opens it, where the match starts on the newline before
  # it.
  run_scenario 'wrapped-undeclared-fails' 1 \
    'docs/x.md:5: undeclared required-check count "3 required contexts"'
  run_scenario 'hyphen-word-fails' 1 \
    'docs/x.md:3: undeclared required-check count "twenty-seven required checks"'
  # Up to two words may sit between the number and "required".
  run_scenario 'two-word-gap-fails' 1 \
    'docs/x.md:3: undeclared required-check count "3 blocking PR required contexts"'
  run_scenario 'context-singular-fails' 1 \
    'docs/x.md:3: undeclared required-check count "1 required context"'

  # --- what is not read ---

  # Fences (blockquoted too) and code spans show the marker and the phrase
  # without claiming them.
  run_scenario 'fenced-passes' 0 '' \
    '0 declared count(s) match 3 required context(s); scanned 2 file(s), 15 prose line(s) (7 fenced line(s) skipped)'

  # History pages, fixture trees and non-Markdown files are outside the scan.
  run_scenario 'excluded-paths-passes' 0 '' \
    '1 declared count(s) match 3 required context(s); scanned 2 file(s), 14 prose line(s)'

  # The formatter would add a blank line before this fence. Reading the
  # fence marker after flushing the paragraph lost the marker's position,
  # so the fence never opened and its closer opened a new one instead.
  local root
  root="$(scratch_root)"
  printf '# Doc\n\nA paragraph that runs into a fence:\n\x60\x60\x60text\n3 required checks\n\x60\x60\x60\n' \
    >"${root}/docs/x.md"
  run_scenario 'fence-after-paragraph-passes' 0 '' \
    '0 declared count(s) match 3 required context(s); scanned 2 file(s), 14 prose line(s) (3 fenced line(s) skipped)' \
    "${root}"
  rm --recursive --force -- "${root}"

  # A fence closes only on a marker of its own character at least as long
  # as its opener, so a shorter or different marker inside it is content.
  root="$(scratch_root)"
  printf '# Doc\n\n\x60\x60\x60\x60text\n\x60\x60\x60\n3 required checks\n\x60\x60\x60\x60\n\n\x60\x60\x60text\n~~~\n4 required checks\n\x60\x60\x60\n' \
    >"${root}/docs/x.md"
  run_scenario 'inner-marker-fence-passes' 0 '' \
    '0 declared count(s) match 3 required context(s); scanned 2 file(s), 13 prose line(s) (8 fenced line(s) skipped)' \
    "${root}"
  rm --recursive --force -- "${root}"

  # A double-backtick span, and one holding a single backtick, are spans;
  # the formatter would rewrite both. \x60 keeps backticks out of the
  # format string, where the shell linter rejects them.
  root="$(scratch_root)"
  printf '# Doc\n\nSpans \x60\x603 required checks\x60\x60 and \x60\x60a \x60 4 required checks\x60\x60 only.\n' \
    >"${root}/docs/x.md"
  run_scenario 'double-backtick-span-passes' 0 '' \
    '0 declared count(s) match 3 required context(s); scanned 2 file(s), 14 prose line(s) (0 fenced line(s) skipped)' \
    "${root}"
  # An unclosed opener is literal text, so what follows it is read.
  printf '# Doc\n\nAn \x60\x60unclosed opener, then 4 required checks.\n' \
    >"${root}/docs/x.md"
  run_scenario 'unclosed-span-fails' 1 \
    'docs/x.md:3: undeclared required-check count "4 required checks"' '' "${root}"
  rm --recursive --force -- "${root}"

  # The Claude-behavior tree counts only where it is tracked: its untracked
  # scratch is not something a commit can fix.
  root="$(scratch_root)"
  mkdir --parents "${root}/.claude"
  printf '# Scratch\n\nEvery PR must pass 9 required checks.\n' >"${root}/.claude/notes.md"
  run_scenario 'claude-untracked-passes' 0 '' \
    '0 declared count(s) match 3 required context(s); scanned 1 file(s), 12 prose line(s) (0 fenced line(s) skipped)' \
    "${root}"
  git -C "${root}" add -- .claude/notes.md
  run_scenario 'claude-tracked-fails' 1 \
    '.claude/notes.md:3: undeclared required-check count "9 required checks"' '' "${root}"
  rm --recursive --force -- "${root}"

  # --- preconditions ---

  run_scenario 'missing-table-exits-2' 2 'required-check-counts: missing'
  run_scenario 'no-section-exits-2' 2 'has no "## Required contexts" section'
  run_scenario 'duplicate-section-exits-2' 2 \
    'has more than one "## Required contexts" section'
  # A table under a later heading is not the Required contexts table.
  run_scenario 'no-table-exits-2' 2 'has no table under "## Required contexts"'
  run_scenario 'no-separator-exits-2' 2 'with no separator row under its header'
  run_scenario 'second-table-exits-2' 2 'has a second table under "## Required contexts"'
  run_scenario 'no-rows-exits-2' 2 'the Required contexts table in docs/security/required-checks.md has no data rows'

  # Built at run time: the formatter closes an unterminated fence.
  root="$(scratch_root)"
  printf '# Doc\n\n\x60\x60\x60text\n3 required checks\n' >"${root}/docs/x.md"
  run_scenario 'unterminated-fence-exits-2' 2 'docs/x.md: unterminated code fence' '' "${root}"
  also_expect 'left a code fence open, so the rest of it went unread'
  rm --recursive --force -- "${root}"

  # A scan root git cannot list must be loud rather than an empty pass.
  root="$(mktemp --directory)"
  mkdir --parents "${root}/docs/security"
  cp -- "${FIXTURES}/clean-passes/docs/security/required-checks.md" \
    "${root}/docs/security/required-checks.md"
  run_scenario 'non-repo-scan-root-exits-2' 2 'failed enumerating the scan set' '' "${root}"
  rm --recursive --force -- "${root}"

  rm --force -- "${LAST_STDERR}"
  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
