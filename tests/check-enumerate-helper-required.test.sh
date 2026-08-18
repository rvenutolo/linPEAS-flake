#!/usr/bin/env bash
# tests/check-enumerate-helper-required.test.sh
#
# Failure-mode harness for scripts/check-enumerate-helper-required.sh.
#
# Each scenario drives the lint through PATHS_OVERRIDE so a fixture is a
# plain file rather than a directory tree, and asserts the diagnostic
# that names the rule branch under test.

set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-enumerate-helper-required.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/enumerate-helper-required"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() {
  printf 'PASS: %s\n' "$1"
}

# @description Run the lint under a given PATHS_OVERRIDE, record the
# outcome with the cross-scenario discrimination gate, and assert exit
# code plus an expected output substring.
# @arg $1 scenario name  @arg $2 PATHS_OVERRIDE value
# @arg $3 expected exit code  @arg $4 expected substring ('' none)
function run_expect() {
  local -r name="$1" paths_override="$2" want_exit="$3" want_msg="$4"
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${paths_override}" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != "${want_exit}" ]]; then
    fail "$(printf '%s: exit %s, want %s' "${name}" "${got_exit}" "${want_exit}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif [[ -n ${want_msg} ]] && ! grep --fixed-strings --quiet -- "${want_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing %q' "${name}" "${want_msg}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

# @description Run against one named fixture; its basename doubles as
# the scenario name.
# @arg $1 fixture basename  @arg $2 expected exit
# @arg $3 expected substring ('' none)
function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  run_expect "${fixture}" "${FIXTURES}/${fixture}" "${want_exit}" "${want_msg}"
}

# The three violating shapes. Each asserts its own file, line and column,
# which is what tells them apart — the trailing sentence of the
# out-of-helper diagnostic is shared by construction.
expect bad-bare-find.sh 1 'bad-bare-find.sh:8:1: find runs outside enumerate_into'
expect bad-bare-git-ls-files.sh 1 'bad-bare-git-ls-files.sh:7:12: git ls-files runs outside enumerate_into'
# An empty rationale is its own finding rather than a silent exemption:
# honoring it would make the marker a way to opt out of stating a reason.
expect bad-empty-rationale.sh 1 \
  'bad-empty-rationale.sh:9:12: enumerate-exempt marker carries no rationale'

# @description A producer name copied to a variable. The command word at
# the use site is then a value, so no single pass can tell what runs
# there. bad-producer-alias.sh is the bare-word scalar form,
# bad-producer-alias-path.sh a scalar full path caught by its basename,
# and bad-producer-alias-array.sh the same copy written as a command
# array, where the producer is one element among several rather than a
# whole value — and, because the array arm reads only element 0,
# bad-producer-alias-array.sh also pins the "head is a producer" side of
# that boundary: git sits first in its array, where a later
# "${lister[@]}" would run it. All three share the alias sentence, so
# file, line and column are what tell them apart.
expect bad-producer-alias.sh 1 \
  'bad-producer-alias.sh:9:8: this assignment copies a producer name to a variable'
expect bad-producer-alias-path.sh 1 \
  'bad-producer-alias-path.sh:8:8: this assignment copies a producer name to a variable'
expect bad-producer-alias-array.sh 1 \
  'bad-producer-alias-array.sh:8:19: this assignment copies a producer name to a variable'

# @description The other side of the same boundary: a producer name at a
# non-head index of an array that is never invoked as a command — the
# shape a tool-presence inventory takes when it merely lists git among
# unrelated tool names. Counting it would flag a compliant tool-check
# array on the strength of one coincidental element, which is exactly the
# false positive the element-0 restriction exists to rule out. Alone,
# good-producer-non-head-array.sh classifies no site at all, so
# good-glob-into.sh's and good-filter-into.sh's own already-proven
# single-site tallies are folded in beside it; the resulting three-file,
# two-site tally is what proves the non-head element was read and passed
# over rather than the file never being scanned.
run_expect 'good-producer-non-head-array' \
  "${FIXTURES}/good-producer-non-head-array.sh"$'\n'"${FIXTURES}/good-glob-into.sh"$'\n'"${FIXTURES}/good-filter-into.sh" \
  0 '3 file(s) scanned, 2 scan site(s) classified, 0 exemption(s)'

# @description A producer named inside the label every compliant
# enumerate_into call passes. The word is data a diagnostic quotes, not a
# command the file runs, and counting it would make every compliant call
# site in this repo a violation of the rule it satisfies. Alone this
# fixture's clean summary is byte-identical to
# good-glob-array-pattern-strings.sh's above — both are a single file with
# one classified site and no exemption — so good-filter-exempt.sh's own
# already-proven single-file tally is folded in beside it; the resulting
# two-file, three-site, one-exemption tally is what separates this proof
# from that sibling rather than the exit code or message shape alone.
run_expect 'good-producer-name-in-label' \
  "${FIXTURES}/good-producer-name-in-label.sh"$'\n'"${FIXTURES}/good-filter-exempt.sh" \
  0 '2 file(s) scanned, 3 scan site(s) classified, 1 exemption(s)'

# @description The negative the interpolated-word guard rests on. A path
# that merely ends in a producer name reaches the assignment through
# interpolation, so it carries no single literal word and is never read as
# the command whose name it happens to end in — proving the word is read
# through literal_word_text rather than by walking every part regardless
# of how the word is built. Alone, good-producer-interpolated-path.sh
# classifies no site at all, so good-glob-into.sh's own already-proven
# single-site tally is folded in beside it; the resulting two-file,
# one-site tally is what proves the interpolated word was read and passed
# over rather than the file never being scanned.
run_expect 'good-producer-interpolated-path' \
  "${FIXTURES}/good-producer-interpolated-path.sh"$'\n'"${FIXTURES}/good-glob-into.sh" \
  0 '2 file(s) scanned, 1 scan site(s) classified, 0 exemption(s)'

# All four clean shapes in one invocation. Each alone prints an
# indistinguishable clean summary, so four scenarios would be four names
# over one observation; the merged summary's counts are what prove all
# four were read — three producer calls (direct, wrapper, exempt) across
# four files, one of them exempted.
#
# Those counts are load-bearing rather than decorative. Mutating the lint
# to stop recognizing a producer handed straight to the helper leaves
# this run at exit 0 and moves only the tally, 3 to 2 — so a scenario
# asserting the exit code, or merely that the run came back clean, would
# score a lint that had gone half-blind as a pass.
run_expect 'all-good-shapes' \
  "${FIXTURES}/good-direct.sh"$'\n'"${FIXTURES}/good-wrapper.sh"$'\n'"${FIXTURES}/good-exempt.sh"$'\n'"${FIXTURES}/good-mentions-only.sh" \
  0 '4 file(s) scanned, 3 scan site(s) classified, 1 exemption(s)'

# The glob rule's violating shapes. A loop that expands its own pattern
# at the loop head has nowhere to state how many files it matched, so an
# empty root produces the clean run a populated one would.
expect bad-bare-glob-loop.sh 1 \
  'bad-bare-glob-loop.sh:10:1: this for loop iterates a glob directly'
expect bad-glob-empty-rationale.sh 1 \
  'bad-glob-empty-rationale.sh:9:1: glob-exempt marker carries no rationale'

# Each rule owns its own marker word, and these two prove the keying in
# both directions: an exemption written for one class must not silence
# the other, or a single marker word would be an opt-out from both rules
# at once no matter which one the site was actually reasoned about.
# The glob rule covers an array assignment as well as a loop head, and
# the diagnostic has to say which one it found: an assignment is not a
# loop, so the loop sentence would send a reader hunting for a `for` that
# is not in the file. Asserting the sentence and not only the exit code
# is what holds the two apart.
expect bad-glob-array-assign.sh 1 \
  'bad-glob-array-assign.sh:11:7: this array assignment expands a glob directly'
expect bad-glob-array-empty-rationale.sh 1 \
  'bad-glob-array-empty-rationale.sh:9:8: glob-exempt marker carries no rationale'

expect bad-glob-marker-mismatch.sh 1 \
  'bad-glob-marker-mismatch.sh:11:1: this for loop iterates a glob directly'
expect bad-producer-marker-mismatch.sh 1 \
  'bad-producer-marker-mismatch.sh:10:12: git ls-files runs outside enumerate_into'

# @description A pattern written literally inside an expansion word.
# A position that reads only the own literal parts of a word cannot see
# it, though it is expanded exactly where a bare one would be. The two
# shapes sit in two fixtures rather than one so each scenario produces
# its own observable output.
expect bad-glob-alt-word-loop.sh 1 \
  'bad-glob-alt-word-loop.sh:11:1: this for loop iterates a glob directly'
expect bad-glob-alt-word-array.sh 1 \
  'bad-glob-alt-word-array.sh:10:7: this array assignment expands a glob directly'

# The glob rule's clean shapes, merged for the same reason the producer
# rule's are: each alone prints an indistinguishable clean summary, and
# the counts are what prove all four were read — a helper call, an
# exempted loop, two helper calls whose only glob is a call argument, and
# a loop over an array that carries no pattern at all.
#
# The tally is load-bearing here too. A rule that stopped counting the
# helper's own call sites would leave this run at exit 0 and move only
# the count, so a scenario asserting the exit code alone would score a
# half-blind rule as a pass.
run_expect 'all-good-glob-shapes' \
  "${FIXTURES}/good-glob-into.sh"$'\n'"${FIXTURES}/good-glob-exempt.sh"$'\n'"${FIXTURES}/good-glob-arg-only.sh"$'\n'"${FIXTURES}/good-no-glob-loop.sh" \
  0 '4 file(s) scanned, 4 scan site(s) classified, 1 exemption(s)'

# One marker word answers for both glob shapes, so an assignment states
# its exemption in exactly the words a loop does. The exemption count is
# what proves the marker was honored rather than the site never having
# been recognized: an unrecognized assignment would also exit 0, at zero
# exemptions.
expect good-glob-array-exempt.sh 0 \
  '1 file(s) scanned, 1 scan site(s) classified, 1 exemption(s)'

# @description Two edge cases in how this lint's own comment record is
# read, merged into one run so the combined tally discriminates from
# every single-file clean summary above. good-glob-exempt-tab-rationale.sh
# carries a rationale with a literal tab right after the marker word:
# the comment record this lint emits is itself a TAB-separated field,
# and that tab lands in the last variable of the shell's own
# `IFS=$'\t' read -r verdict line col what`, which absorbs the rest of
# the record whole, so the marker is still recognized and the
# rationale still non-empty.
# good-glob-exempt-backslash-continuation.sh's marker line ends in a
# trailing backslash, which gets a `shfmt` comment node whose own Text
# embeds that backslash and the newline terminating it, rather than
# reading as continued into the next comment line; the embedded
# newline ends the shell `read` that parses this lint's own comment
# record early, but only after the marker word and its rationale, so
# the exemption is still recognized. Alone, each of these two prints
# the same single-file clean summary `good-glob-array-exempt.sh`
# already asserts above; merged, the two-file, two-exemption tally is
# what proves both were read as marker lines rather than one masking
# the other.
run_expect 'good-glob-exempt-comment-record-edge-cases' \
  "${FIXTURES}/good-glob-exempt-tab-rationale.sh"$'\n'"${FIXTURES}/good-glob-exempt-backslash-continuation.sh" \
  0 '2 file(s) scanned, 2 scan site(s) classified, 2 exemption(s)'

# @description The negative the whole rule rests on. Patterns reach
# `glob_into` as quoted strings and are expanded inside the helper, so a
# metacharacter inside quotes is not a scan whose breadth went
# unasserted. Were the assignment rule to count one, every compliant call
# site in this repo would become a violation of the rule it satisfies —
# and the single classified site here is the `glob_into` call alone, so a
# rule that started counting the two quoted-pattern assignments would
# move this line rather than merely failing.
expect good-glob-array-pattern-strings.sh 0 \
  '1 file(s) scanned, 1 scan site(s) classified, 0 exemption(s)'

# @description A pattern laundered through a variable. The metacharacter
# is written at the assignment and expanded at the read, so the shape is
# decided by how the read is quoted rather than by how the assignment is
# written — which is why the diagnostic names the variable rather than
# only its position.
#
# shellcheck disable=SC2016 # the brace pair is a literal substring of the diagnostic, not an expansion
expect bad-glob-var-loop.sh 1 \
  'bad-glob-var-loop.sh:12:1: this for loop expands ${pat}'
# shellcheck disable=SC2016 # the brace pair is a literal substring of the diagnostic, not an expansion
expect bad-glob-var-array.sh 1 \
  'bad-glob-var-array.sh:11:7: this array assignment expands ${pat}'
# A quoted metacharacter in an array element is not a site the array
# position classifies, so the source is invisible there and the unquoted
# read is the only place the breadth question can be asked.
# shellcheck disable=SC2016 # the brace pair is a literal substring of the diagnostic, not an expansion
expect bad-glob-var-quoted-source-array.sh 1 \
  'bad-glob-var-quoted-source-array.sh:12:1: this for loop expands ${pats}'

# @description The clean counterparts, merged so the tally discriminates
# them from every single-file clean summary already asserted above. A
# quoted read expands no pattern; a value whose only metacharacter
# arrived inside a parameter expansion holds no pattern to expand; and a
# read of a name whose pattern is expanded at an already-classified,
# already-marked site asks a question that site answered. The counts are
# load-bearing: a rule that started classifying any of these three would
# move this line rather than merely failing.
run_expect 'all-good-glob-var-shapes' \
  "${FIXTURES}/good-glob-var-quoted-read.sh"$'\n'"${FIXTURES}/good-glob-var-param-pattern.sh"$'\n'"${FIXTURES}/good-glob-var-classified-source.sh" \
  0 '3 file(s) scanned, 3 scan site(s) classified, 1 exemption(s)'

# @description A read under a plus operator emits the alternate word and
# never the value of the parameter, so a pattern the variable holds
# cannot expand there. Alone this fixture's clean summary is
# byte-identical to good-glob-array-pattern-strings.sh's above — a single
# file with one classified site and no exemption — so good-glob-into.sh's
# and good-glob-arg-only.sh's own already-proven tallies are folded in
# beside it; the resulting three-file, four-site tally is what proves the
# read was reached and dismissed rather than the file never having been
# walked.
run_expect 'good-glob-var-alternate-word' \
  "${FIXTURES}/good-glob-var-alternate-word.sh"$'\n'"${FIXTURES}/good-glob-into.sh"$'\n'"${FIXTURES}/good-glob-arg-only.sh" \
  0 '3 file(s) scanned, 4 scan site(s) classified, 0 exemption(s)'

# The filter rule's violating shapes. filter_into narrows an already
# enumerated set, and a read of the same *_FILTER variable elsewhere
# throws that guarantee away wherever it happens: the two files below
# cover a for-loop body and a while-loop body, and a marker written for
# the glob rule proves it does not excuse this one.
#
# All three share the loop-read diagnostic's trailing sentence, so file,
# line and column are what tells them apart, the same discrimination the
# glob rule's loop-vs-array pair already rests on above.
expect bad-filter-in-for-loop.sh 1 \
  'bad-filter-in-for-loop.sh:12:22: this loop reads a filter variable directly'
expect bad-filter-in-while-loop.sh 1 \
  'bad-filter-in-while-loop.sh:12:22: this loop reads a filter variable directly'
expect bad-filter-marker-mismatch.sh 1 \
  'bad-filter-marker-mismatch.sh:15:22: this loop reads a filter variable directly'

# @description A comment that only quotes the marker word is prose about
# the escape hatch, not the escape hatch. All three rules key off the
# same matcher, so all three are proven: a mention that excused a site
# would make every doc sentence naming a marker an exemption for whatever
# happened to sit under it.
expect bad-prose-quoted-glob-marker.sh 1 \
  'bad-prose-quoted-glob-marker.sh:12:1: this for loop iterates a glob directly'
expect bad-prose-quoted-enumerate-marker.sh 1 \
  'bad-prose-quoted-enumerate-marker.sh:11:1: git ls-files runs outside enumerate_into'
expect bad-prose-quoted-filter-marker.sh 1 \
  'bad-prose-quoted-filter-marker.sh:17:9: this loop reads a filter variable directly'

# @description A comment block that names the marker in prose, ending
# that sentence on the word itself, sits directly above the real marker
# that exempts this site. A matcher that reads the rationale from the
# first raw occurrence of the marker word in the joined block — rather
# than from the comment that actually opens with it — strips to the
# prose sentence's own trailing colon and finds nothing after it before
# the line break, so a genuinely well-formed exemption is misread as
# carrying no rationale and the site wrongly stays a hit. The exemption
# succeeding at exit 0 is what proves the rationale came from the marker
# comment itself rather than from whichever comment happened to end in
# the word first. Alone, this fixture's clean summary is byte-identical
# to good-glob-array-exempt.sh's — both are a single file with one
# classified site and one exemption — so good-glob-into.sh's own single
# non-exempt site is folded in beside it; the resulting two-file tally is
# what separates this proof from that sibling rather than the exit code
# or message shape alone.
run_expect 'good-marker-after-prose-quote' \
  "${FIXTURES}/good-marker-after-prose-quote.sh"$'\n'"${FIXTURES}/good-glob-into.sh" \
  0 '2 file(s) scanned, 2 scan site(s) classified, 1 exemption(s)'

# The loop rule covers a while loop's input as well as its body: a
# `done < <(…)` redirect, a `done <<<"…"` herestring, and an upstream
# `… | while` pipeline stage are all part of what the loop consumes,
# even though none sits inside the bare `WhileClause` node, which ends
# at `done`. Same discrimination as the trio above — file, line and
# column separate these three from each other and from the rest.
expect bad-filter-while-redirect.sh 1 \
  'bad-filter-while-redirect.sh:15:55: this loop reads a filter variable directly'
expect bad-filter-while-herestring.sh 1 \
  'bad-filter-while-herestring.sh:15:57: this loop reads a filter variable directly'
expect bad-filter-pipeline.sh 1 \
  'bad-filter-pipeline.sh:12:46: this loop reads a filter variable directly'

# A file that reads its filter but never narrows anything with it: no
# call site asserts that the selection the read implies is non-empty.
# bad-filter-bare-name.sh below reads a filter without calling
# filter_into too, so the message alone no longer discriminates this
# scenario from that sibling; the file:line:col prefix is what still
# does.
expect bad-filter-no-helper.sh 1 \
  'bad-filter-no-helper.sh:7:14: this script reads a filter variable but never calls filter_into'

# An empty rationale on the filter marker is its own finding, exactly as
# the enumerate and glob markers already require above. The file:line:col
# prefix is asserted the same way its three sibling empty-rationale
# scenarios are, so a position-reporting regression on this path is
# caught rather than masked by the marker word alone.
expect bad-filter-empty-rationale.sh 1 \
  'bad-filter-empty-rationale.sh:13:22: filter-exempt marker carries no rationale'

# The filter rule's clean shapes. good-filter-into.sh and
# good-filter-file-scope-read.sh both read their filter once outside any
# loop and call filter_into — the second file's extra read, guarding a
# job-count assertion the way check-egress-allowlist.sh and
# check-permission-scopes.sh both do, adds no classified site of its own.
# good-filter-into-in-loop.sh calls filter_into from inside a loop body
# instead of at file scope, which exercises a different branch of the
# rule: the call's own filter-value argument sits inside the loop's
# extent, and the rule has to exclude that argument from counting as a
# direct loop read of its own accord, not merely because a file-scope
# call never lands inside a loop's extent to begin with. Alone, each of
# the three prints an indistinguishable single-call clean summary — for
# good-filter-into-in-loop.sh that summary is even byte-identical to an
# unrelated glob scenario's. Merged into one run, the file and
# classified-site counts are what prove all three were read rather than
# one masking the others.
run_expect 'good-filter-shapes' \
  "${FIXTURES}/good-filter-into.sh"$'\n'"${FIXTURES}/good-filter-file-scope-read.sh"$'\n'"${FIXTURES}/good-filter-into-in-loop.sh" \
  0 '3 file(s) scanned, 3 scan site(s) classified, 0 exemption(s)'

# @description A `&&` or `||` chain onto a loop is the guard of the
# loop, not its input, so the filter read in the chained condition stays
# a file-scope read even though the loop sits on the right-hand side of
# the same BinaryCmd. good-filter-and-chain.sh and good-filter-or-chain.sh
# each read their filter once, in the chained condition, and call
# filter_into elsewhere — alone, each prints the same single-call clean
# summary every other file-scope-read fixture above does. Merged into
# one run, the two-file, two-site tally is what proves both operators
# were read as the guard shape rather than swallowed into the range of
# the loop that follows them.
run_expect 'good-filter-chain-shapes' \
  "${FIXTURES}/good-filter-and-chain.sh"$'\n'"${FIXTURES}/good-filter-or-chain.sh" \
  0 '2 file(s) scanned, 2 scan site(s) classified, 0 exemption(s)'

# @description A filter read reached through a function a loop calls. By
# position the read is at file scope, and the file's own filter_into call
# satisfies the missing-helper arm, so both of the rule's other arms are
# quiet — the hop is the only thing that sees it. The diagnostic names the
# function shape rather than the loop shape, because a reader sent hunting
# for a read inside the loop body will not find one.
expect bad-filter-in-called-function.sh 1 \
  'bad-filter-in-called-function.sh:14:9: this filter read sits in a function a loop calls'

# @description The rule reaches exactly one hop. These two files pin the
# boundary from both sides: a two-hop chain stays legal, and a called
# function that reads no filter is not a site. Alone, this pair's tally
# would be byte-identical to good-filter-chain-shapes' own two-file,
# two-site, zero-exemption summary above, and a three-file fold-in lands on
# good-filter-shapes' three-file, three-site tally the same way, so
# good-filter-into.sh and good-filter-file-scope-read.sh — each already
# proven elsewhere to classify as exactly one clean site — are both folded
# in beside them; the resulting four-file, four-site tally is what proves
# all four were read rather than one masking the others, and separates
# this proof from both siblings rather than the exit code or message shape
# alone.
run_expect 'good-filter-hop-boundary' \
  "${FIXTURES}/good-filter-two-hop-documented-gap.sh"$'\n'"${FIXTURES}/good-filter-function-no-read.sh"$'\n'"${FIXTURES}/good-filter-into.sh"$'\n'"${FIXTURES}/good-filter-file-scope-read.sh" \
  0 '4 file(s) scanned, 4 scan site(s) classified, 0 exemption(s)'

# @description A function declared inside a loop body, and called by that
# same loop, has a body whose offset range sits inside both the loop's own
# extent and the hop the loop reaches: the read must keep reporting as a
# loop read rather than double-counting as a function read too. Asserting
# the loop diagnostic's exact position discriminates this fixture from
# every sibling; the hand check below additionally confirms the function
# diagnostic never appears, which the shared discrimination gate cannot
# express on its own since dozens of other bad-* fixtures already print
# the generic failure-count trailer this scenario would otherwise have to
# lean on.
function expect_loop_nested_function() {
  local -r name='bad-filter-loop-nested-function.sh'
  local -r want_msg='bad-filter-loop-nested-function.sh:18:21: this loop reads a filter variable directly'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${FIXTURES}/bad-filter-loop-nested-function.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${want_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the loop diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif grep --fixed-strings --quiet -- 'this filter read sits in a function a loop calls' "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output also carries the function diagnostic — the same read double-reported' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_loop_nested_function

# @description A loop read carrying a valid filter-exempt marker is
# counted as an exemption rather than a hit, the same shape the glob
# rule's own exempt fixtures prove above. The count pairs — one call site
# plus one exempted loop site — separate this from every other single-file
# tally already asserted in this file.
expect good-filter-exempt.sh 0 \
  '1 file(s) scanned, 2 scan site(s) classified, 1 exemption(s)'

# @description A variable named exactly `FILTER` is a filter variable.
# The predicate keys on the name, so a pattern admitting only a suffixed
# form leaves the bare word invisible while the rule's prose claims the
# position is what decides. The read sits inside a loop and the file
# never calls filter_into, so both the loop-read and the missing-helper
# arms fire from the widened name alone; both are asserted by their own
# file:line:col so this scenario stays self-discriminating once the
# missing-helper message is shared with bad-filter-no-helper.sh below.
function expect_filter_bare_name() {
  local -r name='bad-filter-bare-name.sh'
  local -r missing_msg='bad-filter-bare-name.sh:8:18: this script reads a filter variable but never calls filter_into'
  local -r loop_msg='bad-filter-bare-name.sh:12:19: this loop reads a filter variable directly'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${FIXTURES}/bad-filter-bare-name.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${missing_msg}" "${outcome_file}" "${out_file}" "${err_file}"
  harness_assert_also "${loop_msg}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${missing_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the missing-helper diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${loop_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the loop-read diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_filter_bare_name

# @description The filter value copied to a name the predicate does not
# match, in both forms the parser distinguishes: a bare assignment, and a
# declaration inside a function. bad-filter-alias.sh's copy is a plain
# assignment at file scope, so it trips only the alias arm.
expect bad-filter-alias.sh 1 \
  'bad-filter-alias.sh:13:6: this assignment copies a filter value to another name'

# @description bad-filter-alias-declared.sh's copy is a `local` inside a
# function the loop calls, the shape a walk reading only bare assignments
# is blind to. That same read also sits in a body the one-hop rule
# reaches, so both diagnostics fire from one run: the alias arm at column
# 14, the position of the copied value itself, and the hop arm at column
# 15, the position of the read the hop rule reports. Both are asserted so
# neither arm silently swallows the other on this shared line.
function expect_filter_alias_declared() {
  local -r name='bad-filter-alias-declared.sh'
  local -r alias_msg='bad-filter-alias-declared.sh:15:14: this assignment copies a filter value to another name'
  local -r hop_msg='bad-filter-alias-declared.sh:15:15: this filter read sits in a function a loop calls'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${FIXTURES}/bad-filter-alias-declared.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${alias_msg}" "${outcome_file}" "${out_file}" "${err_file}"
  harness_assert_also "${hop_msg}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${alias_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the alias diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${hop_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the hop diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_filter_alias_declared

# @description The copy this repo's own filter sites write. Its target is
# itself a filter name, so the value stays inside the set of names the
# rule can see. Alone this fixture's clean summary is byte-identical to
# good-glob-array-pattern-strings.sh's above — both are a single file with
# one classified site and no exemption — so good-glob-arg-only.sh's own
# already-proven single-file tally is folded in beside it; the resulting
# two-file, three-site tally is what separates this proof from that
# sibling rather than the exit code or message shape alone.
run_expect 'good-filter-sanctioned-alias' \
  "${FIXTURES}/good-filter-sanctioned-alias.sh"$'\n'"${FIXTURES}/good-glob-arg-only.sh" \
  0 '2 file(s) scanned, 3 scan site(s) classified, 0 exemption(s)'

# @description A marker on a file holding no site of its kind excuses
# nothing and is reported rather than counted. The scan-site tally is zero
# here, so the documented empty-scan valve is set: the orphan report is
# the finding, not the absence of scans.
function expect_orphan_no_site() {
  local -r name='orphan-marker-no-site'
  local -r want_msg='bad-orphan-glob-marker.sh:9: glob-exempt marker excuses no site this rule matches'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  LINT_ALLOW_EMPTY_SCAN=1 PATHS_OVERRIDE="${FIXTURES}/bad-orphan-glob-marker.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${want_msg}" "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${want_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing %q' "${name}" "${want_msg}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_orphan_no_site

# @description A marker one blank line above its site reaches nothing,
# which is the case a per-file predicate cannot see: the file does hold a
# site of exactly that kind. Both findings come from the same invocation,
# so they are asserted on one record via harness_assert_also rather than
# as two separate `expect` calls: driving the script twice against the
# same fixture would produce two byte-identical records asserting
# different substrings, which is exactly the collapsed-coverage shape the
# discrimination gate exists to catch. Asserting both substrings here
# still proves the orphan arm and the loop arm fire together from one run
# rather than one masking the other.
function expect_orphan_off_by_one() {
  local -r name='bad-orphan-marker-off-by-one.sh'
  local -r orphan_msg='bad-orphan-marker-off-by-one.sh:9: glob-exempt marker excuses no site this rule matches'
  local -r loop_msg='bad-orphan-marker-off-by-one.sh:11:1: this for loop iterates a glob directly'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  PATHS_OVERRIDE="${FIXTURES}/bad-orphan-marker-off-by-one.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${orphan_msg}" "${outcome_file}" "${out_file}" "${err_file}"
  harness_assert_also "${loop_msg}"

  if [[ ${got_exit} != 1 ]]; then
    fail "$(printf '%s: exit %s, want 1' "${name}" "${got_exit}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${orphan_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the orphan diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${loop_msg}" "${out_file}" "${err_file}"; then
    fail "$(printf '%s: output missing the glob-loop diagnostic' "${name}")"
    cat -- "${out_file}" "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_orphan_off_by_one

# @description The orphan census's own breadth. A clean file prints the
# count it checked rather than staying silent, so a census that stopped
# running is visible here instead of being indistinguishable from a tree
# with no stale marker in it. good-glob-exempt.sh, the fixture the plan
# for this scenario names, ties good-glob-array-exempt.sh's tally
# byte-for-byte once the new field is appended (1/1/1/0 either way), so
# good-glob-arg-only.sh stands in: its two-site tally is unique across
# every scenario already asserted in this file.
expect good-glob-arg-only.sh 0 \
  '1 file(s) scanned, 2 scan site(s) classified, 0 exemption(s), 0 orphan marker(s)'

# @description The producer tally is its own breadth assertion, separate
# from the file enumeration: a real file can be scanned and yield no
# producer at all. That has to be a could-not-run rather than the clean
# summary a genuinely enumeration-free tree prints, because a grammar
# that stopped recognizing producers would report exactly the same line.
run_expect 'zero-producer-scan' "${FIXTURES}/good-mentions-only.sh" 2 \
  'classified 0 scan site(s) across 1 file(s) scanned'

# @description Same input, opted out: proves the documented release
# valve turns that run green rather than only existing in prose.
function expect_zero_producer_allowed() {
  local -r name='zero-producer-scan-allowed'
  local out_file err_file outcome_file got_exit=0
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  LINT_ALLOW_EMPTY_SCAN=1 PATHS_OVERRIDE="${FIXTURES}/good-mentions-only.sh" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" '1 file(s) scanned, 0 scan site(s) classified, 0 exemption(s)' \
    "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 0 ]]; then
    fail "$(printf '%s: exit %s, want 0' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- '1 file(s) scanned, 0 scan site(s) classified, 0 exemption(s)' "${out_file}"; then
    fail "$(printf '%s: stdout missing the clean summary' "${name}")"
    cat -- "${out_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_zero_producer_allowed

# @description A path named in the scan set that is not there is
# operator input pointing at nothing, which is a could-not-run rather
# than a file to drop quietly from the set.
run_expect 'absent-named-path' "${FIXTURES}/no-such-fixture.sh" 2 \
  'named in the scan set but not found'

# @description Drive the enumeration itself rather than a fixture: with
# PATHS_OVERRIDE unset the lint enumerates through `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output — the
# should-be could-not-run that collapses into a clean-looking empty scan
# unless `enumerate_into` catches it.
function expect_empty_scan() {
  local -r name='empty-scan'
  local out_file err_file outcome_file got_exit=0 index_dir
  index_dir="$(mktemp --directory)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  (cd "${REPO_ROOT}" &&
    GIT_INDEX_FILE="${index_dir}/absent.idx" "${SCRIPT}") \
    >"${out_file}" 2>"${err_file}" || got_exit=$?
  rm --recursive --force -- "${index_dir}"
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'enumerated 0 files via git ls-files' \
    "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 2 ]]; then
    fail "$(printf '%s: exit %s, want 2' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'enumerated 0 files via git ls-files' "${err_file}"; then
    fail "$(printf '%s: stderr missing the empty-scan diagnostic' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_empty_scan

# @description A file that is not valid shell defeats `shfmt --to-json`
# outright: with no syntax tree to walk, the lint must report a
# could-not-run rather than read the empty result as a clean file. Built
# at runtime rather than committed, because a tracked file that fails to
# parse as shell would fail this repo's own shellcheck and shfmt hooks on
# every future commit.
function expect_unparsable_shell() {
  local -r name='unparsable-shell'
  local bad_file out_file err_file outcome_file got_exit=0
  bad_file="$(mktemp --suffix=.sh)"
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  outcome_file="$(mktemp)"
  printf '%s\n' '#!/usr/bin/env bash' 'find . -name "unterminated' >"${bad_file}"
  PATHS_OVERRIDE="${bad_file}" \
    "${SCRIPT}" >"${out_file}" 2>"${err_file}" || got_exit=$?
  rm --force -- "${bad_file}"
  printf 'harness-assert-outcome: exit=%d\n' "${got_exit}" >"${outcome_file}"
  harness_assert_record "${name}" 'shfmt could not parse this file as shell for AST inspection' \
    "${outcome_file}" "${out_file}" "${err_file}"

  if [[ ${got_exit} != 2 ]]; then
    fail "$(printf '%s: exit %s, want 2' "${name}" "${got_exit}")"
    cat -- "${err_file}" >&2
  elif ! grep --fixed-strings --quiet -- 'shfmt could not parse this file as shell for AST inspection' "${err_file}"; then
    fail "$(printf '%s: stderr missing the parse-failure diagnostic' "${name}")"
    cat -- "${err_file}" >&2
  else
    pass "${name}"
  fi
  rm --force -- "${out_file}" "${err_file}" "${outcome_file}"
}

expect_unparsable_shell

harness_assert_verify || failures=$((failures + 1))

if ((failures > 0)); then
  printf '\n%d test(s) failed\n' "${failures}" >&2
  exit 1
fi
printf '\nall tests passed\n'
