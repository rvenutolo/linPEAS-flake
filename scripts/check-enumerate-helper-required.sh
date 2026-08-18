#!/usr/bin/env bash
# scripts/check-enumerate-helper-required.sh
#
# @description Lint: every filesystem scan in a repo script or test
# harness asserts its own breadth. The scan set is `scripts/*.sh` plus
# `tests/*.test.sh`, less `tests/fixtures/` — a tree whose files exist to
# be violations of this lint, driven through PATHS_OVERRIDE by the
# harness that asserts the diagnostics they produce.
# An enumeration runs through `enumerate_into`
# (scripts/lib/enumerate.sh) — a producer (`find`, `git ls-files`, `git
# ls-tree`) may appear only as an argument to the helper, inside a
# function the helper is handed by name, or behind an inline
# `# enumerate-exempt: <rationale>` marker. Copying a producer word to a
# variable is banned at that same assignment, since the use site's
# command word is then a value no single pass can resolve; the array
# form is read only at element 0, its command head, so a producer word
# planted at a non-head index and later spliced into command position by
# index arithmetic still evades. A glob-driven scan fills its
# array through `glob_into` — neither a `for` loop at its own head nor an
# array assignment in its element list may expand a pattern, unless an
# inline `# glob-exempt: <rationale>` marker says an empty match set is
# that site's normal state. A filter-driven scan narrows an
# already-enumerated set through `filter_into` — a variable named `FILTER`
# or ending `_FILTER` may be read at file scope to reach that call, but
# not again inside a `for` or `while` loop over the narrowed selection,
# nor in a function that loop calls — one hop out; a function called only
# by that function still evades and stays outside what this pass decides
# — and not at all in a file that never calls `filter_into`, unless an
# inline `# filter-exempt: <rationale>` marker says the direct read is
# deliberate. Copying a filter value into a target whose own name does not
# match that same pattern is a violation at the assignment, wherever the
# copy is later read, because every one of the checks above keys on the
# name of the variable being read and a value under a fresh name would
# otherwise satisfy the letter of all three while re-introducing the
# defect. Those four are the positions a single pass over the tree
# decides; a pattern that reaches a scan by any other route is outside
# what this lint sees, and the rule is stated no wider than that.
#
# Every marker must open its comment: the comment's text is read from
# the syntax tree, not the raw line, and the marker word has to be the
# first thing in it — which is what makes the match immune to a `#`
# inside a string or an expansion earlier on the line.
#
# The property being protected is scan breadth, not producer status. A
# producer that fails is the easy half; the hard half is a producer that
# succeeds and enumerates nothing: `GIT_INDEX_FILE=/nonexistent git
# ls-files` exits 0 and prints not one path, which every status check in
# the world reads as a clean tree. A lint that scans an empty set finds
# no violations and exits 0 — off, and green. So breadth has to be
# asserted rather than inferred, and `enumerate_into` is where that
# assertion lives: routing every enumeration through it makes the
# assertion structural instead of something each call site has to
# remember.
#
# A glob scan fails the same way from the other end. Under `nullglob` a
# pattern matching nothing expands to nothing: a loop body never runs, an
# array comes back empty, no violation is found and the run exits 0 — so
# a scan root that exists and holds nothing scores as a clean tree.
# `glob_into` is the same assertion for both shapes: it expands the
# patterns, fills the array and refuses an empty match set, and whatever
# reads that array afterwards walks an ordinary list.
#
# A filter-driven scan fails a third way, one layer past enumeration and
# globbing: `filter_into` narrows a set the other two helpers already
# proved non-empty, and it is the one place that narrowing's own
# cardinality is asserted. A loop that reads the raw filter variable
# again — directly in its own body, or one hop out in a function the loop
# calls by name — instead of trusting the selection `filter_into` handed
# back, re-applies the filter test outside the helper. Whether that second
# application runs over the narrowed selection — where it is merely
# redundant, since every path there already matched — or over a set the
# helper never narrowed is not decidable at the read site, and the
# second is the empty-root failure the helper exists to catch: a filter
# matching nothing selects no path, the loop body never fires, and the
# run exits 0. A file that reads a filter variable and never calls
# `filter_into` at all is the same hole with no call site to point to:
# nothing anywhere in that file asserts the selection the read implies
# is non-empty.
#
# A filter-driven scan fails a fourth way, sideways rather than past any
# of the first three: copying the filter value into a variable whose own
# name is not `FILTER` or `*_FILTER` moves every later read of that copy
# outside all three checks above at once, because each one keys on the
# name of the variable being read rather than tracing where its value
# came from. The copy is flagged at the assignment regardless of where or
# how many times the copied name is later read, which is what keeps the
# rule decidable in one pass rather than requiring the kind of dataflow
# tracing the other three checks were built to avoid.
#
# That is what makes all three rules decidable in one pass. Associating a
# scan with a cardinality test written an arbitrary distance later is not
# something a textual rule can do; asking whether a producer is an
# argument to the helper is local to one call expression, so is asking
# whether a `for` loop or an array assignment expands a pattern in its
# own words, and so is asking whether a filter-named read falls inside a
# loop's own extent or outside every `filter_into` call in the file.
# Patterns handed to `glob_into` are arguments of a `CallExpr` — never
# `WordIter` items, never array elements — and reach it quoted, so a
# compliant call site cannot false-hit the glob rule however many
# metacharacters it carries. A filter-named read handed to `filter_into`
# as its own argument is excluded from the filter rule the same way, and
# the sanctioned `readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"` shape
# stays legal under the alias check for the same reason: its own target is
# itself a filter name, so a compliant call site cannot false-hit either
# rule it satisfies.
#
# Detection parses each script's syntax tree via `shfmt --to-json` (the
# mvdan.cc/sh parser `shfmt` and `treefmt` already run over this repo)
# rather than matching text, because three shapes here name the banned
# commands without running them and a textual rule would need a
# special case for each: this file's own prose, the label string every
# compliant call site passes (`enumerate_into paths 'git ls-files' git
# ls-files -z …`), and heredocs documenting the idiom. None of them is a
# command node, so none of them is a hit.
#
# A `git` invocation's subcommand is found by walking past the global
# flags (`-C <dir>`, `-c <k>=<v>`, `--git-dir=…`) rather than by reading
# the word right after `git`: the one hand-rolled enumeration this lint
# was written against spelled it `git -C "${ROOT}" ls-files`.
#
# The count of scan sites classified — producer calls plus `glob_into`
# call sites plus glob loops plus glob array assignments plus
# `filter_into` call sites, plus filter reads inside a loop, plus the
# single read reported in a file that calls the helper nowhere, plus a
# filter value copied to an unwatched name — is itself asserted nonzero
# (unless LINT_ALLOW_EMPTY_SCAN=1). A grammar that
# silently recognized nothing would report "0 violations" and exit 0 —
# the same clean line a genuinely scan-free tree prints — leaving this
# gate off while green, which is the exact failure it exists to prevent
# one level down.
#
# Each rule owns its own marker word, and a marker excuses only the kind
# of site it names: a rationale for running a producer outside the
# enumeration helper says nothing about whether a glob's match set may
# come back empty or a loop may read a filter variable directly, and the
# reverse holds in every direction.
#
# A site a marker was written for can still be rewritten into a
# compliant shape, moved, or dropped from the file entirely while the
# comment above it stays behind, so every marker word this lint owns is
# censused independently of whichever rule's sites a file happens to
# hold today: a `# glob-exempt:` comment sitting where the glob rule
# finds nothing to excuse is unconsumed exactly like an
# `# enumerate-exempt:` comment would be, because a marker protecting
# nothing keeps asserting the decision it was written for regardless of
# which of the three words it is spelled with. A marker classification
# never consumed while walking a file is reported on its own line, and
# the clean summary line carries the count as a fourth field alongside
# files scanned, sites classified and exemptions applied.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures, and
# LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose scan-site tally (or whose
# enumerated file count) comes back zero.
# Exit 0 clean, 1 on a producer outside `enumerate_into`, a producer name
# copied to a variable, a `for` loop expanding a glob at its own head, an
# array assignment expanding one in its element list, a loop reading a
# filter variable directly, a filter read in a function that loop calls,
# a script reading a filter variable without ever calling `filter_into`,
# an assignment copying a filter value to a name outside the filter
# pattern, an exemption marker with no rationale, or an exemption marker
# that excuses no site this pass classified, 2 when a required tool is
# absent, the scan set could not be enumerated (or classified nothing),
# a named path does not exist, or a file could not be parsed as shell.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

# A missing `shfmt` or `jq` must be diagnosed as itself rather than as
# the per-file "could not parse" message below, which is reserved for a
# file that genuinely fails to parse once both tools are known present.
require_tool shfmt
require_tool jq

# @description NUL-delimited producer for `enumerate_into`. Each pathspec
# crosses `/`, so `scripts/*.sh` covers `scripts/lib/` as well as the top
# level and `tests/*.test.sh` reaches a harness at any depth. Test
# harnesses scan the tree the same way the scripts they drive do — a
# harness whose own enumeration comes back empty asserts nothing about
# the script under test and still exits 0 — so they are held to the same
# rule.
#
# `tests/fixtures/` is excluded because that tree holds files written to
# be violations of this lint: this lint's own harness feeds them in
# through PATHS_OVERRIDE and asserts the diagnostics they produce.
# Gating the fixture tree here would make the lint flag its own test
# inputs, and marking them exempt would destroy what they test. The
# exclusion is a pathspec rather than a name filter because fixture files
# are named after the harness shapes they imitate, `.test.sh` included.
# @stdout NUL-delimited paths
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function enumerate_helper_git_sources() {
  git ls-files -z -- 'scripts/*.sh' 'tests/*.test.sh' ':(exclude)tests/fixtures/*'
}

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  enumerate_into paths 'git ls-files' enumerate_helper_git_sources
fi

# The jq program walks one file's shfmt --to-json tree per run
# (--to-json accepts only stdin, one document per invocation) and emits
# one `<ok|bad>\t<line>\t<col>\t<what>` record per scan site, where
# `<what>` is the producer name for an enumeration and one of the shape
# literals below for a glob-driven scan. The shell loop keys its marker
# word off that field, so an exemption written for one rule cannot
# silence the other.
#
# Three positions are recognized for a producer, and each is counted:
#   ok  — the producer's words are arguments of an `enumerate_into` call
#   ok  — the producer runs inside a function whose name that same file
#         hands to `enumerate_into`
#   bad — anywhere else
#
# Three are recognized for a glob scan:
#   ok  — a `glob_into` call, which owns the match set and its size
#   bad — a `for` whose iteration words carry a glob metacharacter
#   bad — an array assignment whose element words carry one
#
# A producer passed directly to the helper is NOT its own command node:
# `enumerate_into arr label git ls-files -z` parses as one call whose
# argument words happen to be `git`, `ls-files`, … So the direct form is
# found by inspecting the helper's own arguments, and the free-standing
# form by looking for a producer command node. The two cannot
# double-count each other, because a word is either an argument of the
# helper call or the head of its own.
#
# The `what` field of a glob or filter record, one literal per shape so
# the diagnostic names the site the reader is looking at rather than
# calling an assignment a loop, or a missing-helper read a loop read.
# Held in variables so the jq program and the shell loop that keys the
# marker word off them cannot drift apart.
readonly GLOB_WHAT='glob loop'
readonly GLOB_ARRAY_WHAT='glob array assignment'
readonly FILTER_WHAT='filter selection'
readonly FILTER_LOOP_WHAT='filter read in a loop'
readonly FILTER_FUNC_WHAT='filter read in a function a loop calls'
readonly FILTER_MISSING_WHAT='filter read without the helper'
readonly FILTER_ALIAS_WHAT='filter value copied to another name'
readonly PRODUCER_ALIAS_WHAT='producer name copied to a variable'
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly JQ_PROG='
# A word yields text only when it is unambiguously static: a bare
# literal, a single-quoted literal, or a double-quoted literal with no
# interpolation. A variable that happens to hold "find" at runtime is
# never mistaken for the command.
def literal_word_text:
  (.Parts // []) as $p
  | if ($p | length) != 1 then null
    else
      $p[0] as $part
      | if $part.Type == "Lit" then $part.Value
        elif $part.Type == "SglQuoted" then ($part.Value // null)
        elif $part.Type == "DblQuoted"
          and (($part.Parts // []) | length) == 1
          and ($part.Parts[0].Type == "Lit")
        then $part.Parts[0].Value
        else null
        end
    end;

def basename_of: if . == null then null else (. | split("/") | last) end;

# Index of the real command word: 0, or 1 behind a `command` prefix.
def cmd_index:
  ((.[0] // {}) | literal_word_text) as $t
  | if $t == "command" then 1 else 0 end;

# `git`s subcommand: the first word that is neither a flag nor the value
# a global flag consumes. `-C` and `-c` each take the next word; the
# `--flag=value` forms carry their own.
def git_subcommand(args):
  def go(a):
    if (a | length) == 0 then null
    else
      (a[0] | literal_word_text) as $t
      | if $t == null then null
        elif ($t == "-C" or $t == "-c") then go(a[2:])
        elif ($t | startswith("-")) then go(a[1:])
        else $t
        end
    end;
  go(args);

# The producer name a word list starts with, or null. Callers pass the
# argument slice beginning at the command word itself.
def producer_of(args):
  if (args | length) == 0 then null
  else
    (args | cmd_index) as $ci
    | ((args[$ci] // {}) | literal_word_text | basename_of) as $head
    | if $head == "find" then "find"
      elif $head == "git" then
        (git_subcommand(args[($ci + 1):])) as $sub
        | if ($sub == "ls-files" or $sub == "ls-tree") then ("git " + $sub) else null end
      else null
      end
  end;

# The literal metacharacters a word writes unquoted: its own bare parts,
# and the alternate or default word of an expansion it holds. A pattern
# inside ${y+*.yml} is written literally at this site exactly as a bare
# one is, and is expanded in the same place; only the level it sits at
# differs. A quoted metacharacter is still not a pattern, which is why
# only a Lit is read at either level.
def bare_lit_globs:
  [ (.Parts // [])[]
    | (select(.Type == "Lit") | (.Value // "")),
      (select(.Type == "ParamExp")
        | ((.Exp.Word.Parts // [])[] | select(.Type == "Lit") | (.Value // ""))) ]
  | [ .[] | select(test("[*?[]")) ];

[.. | objects | select(.Type == "FuncDecl")
  | {name: .Name.Value, from: .Body.Pos.Offset, to: .Body.End.Offset}] as $funcs

# Every `enumerate_into` call, with the argument slice that follows the
# array name and the label.
| [.. | objects | select(.Type == "CallExpr")
    | select(((.Args // []) | length) > 0)
    | select((.Args[0] | literal_word_text) == "enumerate_into")] as $enum_calls

# Function names this file hands to the helper. Any literal argument is
# considered, not only the producer slot: the helper takes the producer
# as a command word list, and a caller is free to pass extra arguments
# after the function name.
| [$enum_calls[] | (.Args // [])[] | literal_word_text | select(. != null)] as $enum_words
| [$funcs[] | select(.name as $n | $enum_words | index($n) != null)] as $sanctioned

# Position 1: producer words handed straight to the helper.
| [$enum_calls[]
    | . as $call
    | (producer_of((.Args // [])[3:])) as $prod
    | select($prod != null)
    | "ok\t\($call.Pos.Line)\t\($call.Pos.Col)\t\($prod)"] as $direct

# Positions 2 and 3: a producer that is the head of its own command.
| [.. | objects | select(.Type == "CallExpr")
    | . as $call
    | (producer_of(.Args // [])) as $prod
    | select($prod != null)
    | ([$sanctioned[]
        | select($call.Pos.Offset >= .from and $call.Pos.Offset < .to)]
      | length) as $inside
    | (if $inside > 0 then "ok" else "bad" end) as $verdict
    | "\($verdict)\t\($call.Pos.Line)\t\($call.Pos.Col)\t\($prod)"] as $standalone

# A producer name copied to a variable. The enumeration rule predicate is
# the literal command word, so a copy leaves the use site head a value and
# nothing in one pass can say what command runs there. Whether the copy is
# ever used as a command is undecidable here, which is why the copy itself
# is the violation, the same reason the filter alias rule fires at its
# assignment rather than at the read.
#
# The word is read through `literal_word_text` and `basename_of`, not by
# walking parts: that keeps `x="${dir}/find"`, an interpolated path that
# merely ends in the name, from being read as the command, while
# `p=/usr/bin/find` is caught by its basename. A bare `git` counts with no
# subcommand present, because the subcommand is written at the use site the
# copy has made unreadable. Both a scalar assignment and an array
# assignment are covered, but the array arm reads only element 0: a
# command array is invoked as `"${arr[@]}"`, so its command head is
# always its first element, and a producer name sitting at any other
# index is data the same way the label text an enumerate_into call
# passes as its own argument is data — counting a non-head element
# would flag a tool inventory, or any other unrelated list, that merely
# names a producer somewhere in its middle. Stated honestly, this reads
# only the element written at index 0: a producer word planted at a
# non-head index and later spliced into command position by index
# arithmetic still evades, and is outside what this pass decides, the
# same kind of boundary the filter rule already states for its own
# one-hop reach rather than implying total coverage.
| [.. | objects | select(has("Name")) | select(.Name.Value != null)
    | . as $a
    | ([($a.Value // empty)] + [((($a.Array // {}).Elems // [])[0].Value // empty)]) as $words
    | (($a.Value // $a.Array) // null) as $rhs
    | select($rhs != null)
    | select(([$words[] | literal_word_text | basename_of
        | select(. == "find" or . == "git")] | length) > 0)
    | "bad\t\($rhs.Pos.Line)\t\($rhs.Pos.Col)\t\($producer_alias_what)"] as $producer_alias

# Position 4: a `glob_into` call. Counted rather than merely ignored, so
# the nonzero tally below covers this rule as well — a walk that stopped
# recognizing the sanctioned shape would otherwise still print a clean
# line.
| [.. | objects | select(.Type == "CallExpr")
    | select(((.Args // []) | length) > 0)
    | select((.Args[0] | literal_word_text) == "glob_into")
    | "ok\t\(.Pos.Line)\t\(.Pos.Col)\t\($glob_what)"] as $glob_calls

# Position 5: a `for` whose iteration words carry a glob metacharacter in
# an unquoted literal, at the word itself or in the alternate or default
# word of an expansion it holds. Only a `Lit` counts at either level: a
# metacharacter inside quotes is not a pattern, so `for x in "*"`
# iterates one literal asterisk and asserts nothing about any tree.
# `.Loop.Items` is empty for a C-style `for ((;;))`, which therefore
# never reaches the test. The site list is kept apart from the records so
# a later position can ask whether this one already classified the site.
| [.. | objects | select(.Type == "ForClause")
    | select(([(.Loop.Items // [])[] | bare_lit_globs[]] | length) > 0)
    | {line: .Pos.Line, col: .Pos.Col}] as $glob_loop_sites
| [$glob_loop_sites[] | "bad\t\(.line)\t\(.col)\t\($glob_what)"] as $glob_loops

# Position 6: an array assignment whose element words carry a glob
# metacharacter in an unquoted literal, read at the same two levels the
# loop head is read at. An `Assign` node carries no `Type` field, so it is
# selected by the `Array` it holds; a scalar assignment holds a null one.
# The position reported is that of the array expression itself, which is
# where the pattern is written.
#
# Only a bare `Lit` part counts, for the same reason it does at a loop
# head, and this is the restriction the whole rule rests on: `x=("*")`
# assigns one literal asterisk and asserts nothing about any tree, and a
# pattern handed to `glob_into` travels as a quoted string
# (`patterns+=("${d}/*.yml")`) to be expanded inside the helper, where
# its match set is asserted. Counting a quoted metacharacter here would
# make every compliant call site a violation of the rule it satisfies.
| [.. | objects | select(has("Array")) | select(.Array != null)
    | select(([(.Array.Elems // [])[] | (.Value // {}) | bare_lit_globs[]] | length) > 0)
    | {line: .Array.Pos.Line, col: .Array.Pos.Col}] as $glob_array_sites
| [$glob_array_sites[] | "bad\t\(.line)\t\(.col)\t\($glob_array_what)"] as $glob_arrays

# The whole extent of the statement that encloses a loop, not the bare
# `ForClause`/`WhileClause` node: that node ends at `done`, but the
# input to a `while` loop — a `done < <(…)` redirect, a `done <<<"…"`
# herestring, or an upstream `… | while` pipeline stage — sits outside
# it while still being part of what the loop consumes, exactly as much
# as a filter read among the iteration words of a `for` is part of what
# it consumes. A statement carries no `Type` field of its own, so it is
# selected by the `Cmd` it holds — the same idiom this file already
# uses for `Assign`/`Array` above — and a pipeline stage is selected by
# walking the right-hand side of a `BinaryCmd`. Selecting on the direct
# `.Cmd` rather than any statement that merely contains a loop
# somewhere inside it is what keeps an `if` block from swallowing its
# own condition into the range of the loop.
#
# `BinaryCmd.Op` is an opaque integer with no name in the JSON, fixed by
# this parser version: 13 is `|`, 14 is `|&`. Only those two extend the
# range of a loop, because only those two feed the loop data — a `&&`
# (11) or `||` (12) chain onto a loop is the guard of the loop, not its
# input: the chained condition decides whether the loop runs at all, and
# that decision is made and read before the loop consumes anything, the
# same relationship an `if` condition already has to a loop in its body.
# Counting every `BinaryCmd` regardless of operator would swallow the
# filter read of that guard into the range of the loop the same way an
# unguarded `if` was already kept from doing, through a different
# operator reaching the same shape.
| ([.. | objects | select(has("Cmd"))
    | select((((.Cmd // {}) | .Type) == "ForClause") or (((.Cmd // {}) | .Type) == "WhileClause"))
    | {from: .Pos.Offset, to: .End.Offset}]
  + [.. | objects | select(.Type == "BinaryCmd")
    | select(.Op == 13 or .Op == 14)
    | select(([(.Y // {}) | .. | objects
        | select(.Type == "ForClause" or .Type == "WhileClause")] | length) > 0)
    | {from: .Pos.Offset, to: .End.Offset}]) as $loops

# Function bodies a loop reaches in ONE hop: a FuncDecl whose name appears
# as a literal command word inside the extent of some loop. A read in such
# a body re-applies the filter test where the loop consumes it, exactly as
# a read written inline would, and by position alone it sits at file scope
# — so the position rule has to follow the call to stay true to what it
# claims.
#
# One hop, deliberately, not a transitive closure: a function called only
# by another function a loop calls still sits outside every extent and
# still evades. The rule is stated no wider than it reaches, in the header
# comment above and in the invariant entry, because a reader who assumes
# total coverage resolves the difference by trusting the wrong half.
| [.. | objects | select(.Type == "CallExpr")
    | select(((.Args // []) | length) > 0)
    | . as $c
    | ($c.Args[0] | literal_word_text) as $w
    | select($w != null)
    | select(([$loops[] | select($c.Pos.Offset >= .from and $c.Pos.Offset < .to)] | length) > 0)
    | $w] as $loop_called
| [$funcs[]
    | select(.name as $n | $loop_called | index($n) != null)
    | {from: .from, to: .to}] as $hop_bodies

| [.. | objects | select(.Type == "CallExpr")
    | select(((.Args // []) | length) > 0)
    | select((.Args[0] | literal_word_text) == "filter_into")] as $filter_calls
| [$filter_calls[] | {from: .Pos.Offset, to: .End.Offset}] as $filter_call_ranges

# A read of a variable named `FILTER` or ending `_FILTER`. The name is
# the whole predicate: this repo spells every fixture-driving filter that
# way, whether alone or suffixed, and a rule keyed on the identity of the
# enclosing script would say nothing about a new one.
| [.. | objects | select(.Type == "ParamExp")
    | select(((.Param.Value // "") | test("(^|_)FILTER$")))
    | . as $r
    | select(([$filter_call_ranges[]
        | select($r.Pos.Offset >= .from and $r.Pos.Offset < .to)] | length) == 0)] as $filter_reads

# An assignment copying a filter value into a target whose own name is not
# a filter name. The copy is the violation, wherever it is later read:
# every arm of this rule keys on the name of the variable being read, and a
# value under a fresh name satisfies the letter of all three while
# re-introducing the defect. Flagging the copy keeps the whole rule
# decidable in one pass, which tracing the value to its read would not.
#
# `local`, `readonly`, `declare` and `export` forms are filed under a
# different node than a bare assignment, so the walk selects any object
# carrying a `Name` rather than the assignment list of a call expression —
# the declared form is the one a copy inside a function actually takes.
#
# A bare assignment (`x=`), a `declare z` or an `export E` with no value
# carries no `Value` key. That is harmless here because the value is only
# ever reached through `.. | objects`: the `..` recursion over `null`
# yields `null`, which `objects` then filters out, so a missing key never
# reaches the ParamExp walk or the position interpolation below. A direct
# index such as `.Value.Parts[]` would not be null-safe the same way.
| [.. | objects | select(has("Name")) | select(.Name.Value != null)
    | . as $a
    | select(($a.Name.Value | test("(^|_)FILTER$")) == false)
    | ($a.Value // $a.Array) as $rhs
    | select(([$rhs | .. | objects | select(.Type == "ParamExp")
        | (.Param.Value // "") | select(test("(^|_)FILTER$"))] | length) > 0)
    | "bad\t\($rhs.Pos.Line)\t\($rhs.Pos.Col)\t\($filter_alias_what)"] as $filter_alias

| [$filter_calls[] | "ok\t\(.Pos.Line)\t\(.Pos.Col)\t\($filter_what)"] as $filter_ok

| [$filter_reads[] | . as $r
    | select(([$loops[] | select($r.Pos.Offset >= .from and $r.Pos.Offset < .to)] | length) > 0)
    | "bad\t\($r.Pos.Line)\t\($r.Pos.Col)\t\($filter_loop_what)"] as $filter_in_loops

# A read inside a hop-reached body that is not already inside the own
# extent of the loop. The two sets are kept apart rather than merged so
# the message can name the function shape: a reader told to look inside
# the loop body will not find the read there.
| [$filter_reads[] | . as $r
    | select(([$loops[] | select($r.Pos.Offset >= .from and $r.Pos.Offset < .to)] | length) == 0)
    | select(([$hop_bodies[] | select($r.Pos.Offset >= .from and $r.Pos.Offset < .to)] | length) > 0)
    | "bad\t\($r.Pos.Line)\t\($r.Pos.Col)\t\($filter_func_what)"] as $filter_in_funcs

| (if (($filter_reads | length) > 0) and (($filter_calls | length) == 0)
    then [$filter_reads[0] | "bad\t\(.Pos.Line)\t\(.Pos.Col)\t\($filter_missing_what)"]
    else [] end) as $filter_missing

# Every comment in the file, emitted ahead of the site records so the
# shell loop has the whole map before it classifies anything. A comment
# is selected by the `Hash` position it carries rather than by a `Text`
# key: an empty `#` line has no `Text` at all, and a selector keyed on
# the text would drop it from a census that has to see every comment.
#
# The text is emitted as-is, tab and newline included. A tab survives
# the tab-delimited shell read below intact: what is the last variable
# that read assigns, and a read with fewer names than fields hands the
# whole remainder — every embedded delimiter included — to the last
# one. A newline can appear too, when a comment line ends in a
# trailing backslash; shfmt embeds that backslash and the terminating
# newline into the same Text field rather than treating the next line
# as a continuation. That newline still ends the shell read early, but
# only after the marker word and its rationale, so the truncated
# record is read complete and the resulting blank continuation record
# is skipped by the zero-length verdict guard the loop below already
# has.
| [.. | objects | select(has("Hash"))
    | "cmt\t\(.Pos.Line)\t\(.Pos.Col)\t\(.Text // "")"] as $comments

| ($comments + $direct + $standalone + $producer_alias + $glob_calls + $glob_loops + $glob_arrays + $filter_ok + $filter_in_loops + $filter_in_funcs + $filter_missing + $filter_alias)[]
'

# The exemption marker word each rule answers to, keyed by the record's
# `what` field. A marker excuses only the kind of site it names: a
# rationale for running a producer outside the enumeration helper is not
# a statement about whether a glob may match nothing, so one word cannot
# be allowed to opt a site out of both rules at once.
#
# The marker sits on the site's own line or in the contiguous comment
# block above it, must open the comment so prose naming it exempts
# nothing, and its rationale must be non-empty — an empty one is drift,
# not an exemption, exactly as the sibling exit-code and patch-tag
# markers treat it. What "open the comment" means is decided from the
# syntax tree rather than the raw line: the comment's text is the
# `Text` a `shfmt --to-json` `Comment` node carries, and the marker word
# has to be the first thing in that text.
readonly MARKER_ENUMERATE='enumerate-exempt'
readonly MARKER_GLOB='glob-exempt'
# Named MARKER_FILTER_WORD rather than MARKER_FILTER: the filter rule's
# own predicate flags any read of a variable whose name ends `_FILTER`,
# and this constant is read at every entry of the map below it populates
# — a shorter name here would make the lint trip over its own control
# plane, a marker word mistaken for the filter value it exists to guard.
readonly MARKER_FILTER_WORD='filter-exempt'

# Which word answers for which shape, keyed by the record's `what` field.
# The glob rule owns more than one shape, so the mapping is a lookup by
# rule rather than a comparison against a single shape literal: a shape
# added to the glob rule and left out of a one-literal test would quietly
# start answering to the producer marker, which says nothing about
# whether a match set may come back empty. A `what` this map does not
# name is a producer name, and producers take the enumeration word.
declare -A MARKER_BY_WHAT=(
  ["${GLOB_WHAT}"]="${MARKER_GLOB}"
  ["${GLOB_ARRAY_WHAT}"]="${MARKER_GLOB}"
  ["${FILTER_WHAT}"]="${MARKER_FILTER_WORD}"
  ["${FILTER_LOOP_WHAT}"]="${MARKER_FILTER_WORD}"
  ["${FILTER_FUNC_WHAT}"]="${MARKER_FILTER_WORD}"
  ["${FILTER_MISSING_WHAT}"]="${MARKER_FILTER_WORD}"
  ["${FILTER_ALIAS_WHAT}"]="${MARKER_FILTER_WORD}"
  ["${PRODUCER_ALIAS_WHAT}"]="${MARKER_ENUMERATE}"
)
readonly MARKER_BY_WHAT

# Every marker word this lint owns. The census below looks for all three
# regardless of which rule a file happens to hold sites for: a marker that
# excuses nothing is a finding whichever word it is spelled with, and a
# census keyed on the sites present would go blind on exactly the file
# whose site left.
readonly MARKER_WORDS=("${MARKER_ENUMERATE}" "${MARKER_GLOB}" "${MARKER_FILTER_WORD}")

scanned=0
classified=0
exempted=0
failed=0
orphans=0
for f in "${paths[@]}"; do
  # A path `git ls-files` enumerated always exists; a path named by
  # PATHS_OVERRIDE is operator input, and one naming a file that is not
  # there is a could-not-run rather than a file to drop from the scan.
  if [[ ! -f ${f} ]]; then
    printf '%s: named in the scan set but not found\n' "${f}" >&2
    exit 2
  fi
  scanned=$((scanned + 1))

  ast_json=""
  if ! ast_json="$(shfmt --to-json <"${f}" 2>/dev/null)"; then
    printf '%s: shfmt could not parse this file as shell for AST inspection\n' "${f}" >&2
    exit 2
  fi

  records=""
  if ! records="$(jq --raw-output --arg glob_what "${GLOB_WHAT}" \
    --arg glob_array_what "${GLOB_ARRAY_WHAT}" --arg filter_what "${FILTER_WHAT}" \
    --arg filter_loop_what "${FILTER_LOOP_WHAT}" --arg filter_func_what "${FILTER_FUNC_WHAT}" \
    --arg filter_missing_what "${FILTER_MISSING_WHAT}" --arg filter_alias_what "${FILTER_ALIAS_WHAT}" \
    --arg producer_alias_what "${PRODUCER_ALIAS_WHAT}" \
    "${JQ_PROG}" <<<"${ast_json}")"; then
    printf '%s: jq failed walking the parsed syntax tree\n' "${f}" >&2
    exit 2
  fi

  # The file is read into an array once, rather than re-read through a
  # `sed | grep` pipeline per finding: under pipefail such a pipeline
  # returns grep's no-match status whether or not the reader failed, so
  # a read failure would be indistinguishable from "no marker here".
  file_lines=()
  mapfile -t file_lines <"${f}"
  declare -A COMMENT_TEXT=()
  declare -A CONSUMED=()

  while IFS=$'\t' read -r verdict line col what; do
    [[ -z ${verdict} ]] && continue

    # Comment records arrive ahead of every site record and are census
    # data, not scan sites: counting one would inflate the tally that
    # exists to prove the grammar still recognizes real scans.
    if [[ ${verdict} == cmt ]]; then
      COMMENT_TEXT["${line}"]="${what}"
      continue
    fi

    classified=$((classified + 1))
    [[ ${verdict} == ok ]] && continue

    # The marker word follows the kind of site, so the exemption a
    # reviewer reads is the one the site was reasoned about.
    marker_word="${MARKER_BY_WHAT[${what}]:-${MARKER_ENUMERATE}}"

    # The marker may sit on the site's own line or anywhere in the
    # contiguous comment block directly above it. A rationale worth
    # reading rarely fits on one line, and a marker that only counted
    # when it landed on the last comment line would push the reason away
    # from the sentence that explains it.
    #
    # The marker has to OPEN its comment: the text a comment carries is
    # read from the syntax tree and the word must be the first thing in
    # it. A comment that merely names the marker — this file's own header
    # does, and so does every doc sentence describing the escape hatch —
    # is prose about the rule, and prose that excused a site would make
    # any sentence naming a marker an exemption for whatever happened to
    # sit beneath it. Reading the text from the tree rather than from the
    # raw line is also what keeps a `#` inside a string or a `${x#y}`
    # expansion from being mistaken for a comment opener.
    marker_line=0
    rationale=''
    probe="${line}"
    while ((probe >= 1)); do
      comment_text="${COMMENT_TEXT[${probe}]:-}"
      trimmed="${comment_text#"${comment_text%%[![:space:]]*}"}"
      if [[ ${trimmed} == "${marker_word}:"* ]]; then
        marker_line="${probe}"
        rationale="${trimmed#"${marker_word}":}"
        # Trim surrounding whitespace without invoking anything.
        rationale="${rationale#"${rationale%%[![:space:]]*}"}"
        rationale="${rationale%"${rationale##*[![:space:]]}"}"
        break
      fi
      # Walk up only while the line above is a comment-only line, which
      # is what makes the block contiguous rather than a search of the
      # whole file.
      [[ ${file_lines[probe - 2]:-} =~ ^[[:space:]]*# ]] || break
      probe=$((probe - 1))
    done

    if ((marker_line > 0)); then
      CONSUMED["${marker_line}"]=1
      if [[ -z ${rationale} ]]; then
        printf '%s:%s:%s: %s marker carries no rationale; %s stays a hit until the marker says why the helper is wrong here\n' \
          "${f}" "${line}" "${col}" "${marker_word}" "${what}" >&2
        failed=$((failed + 1))
      else
        exempted=$((exempted + 1))
      fi
      continue
    fi

    case ${what} in
    "${GLOB_WHAT}")
      printf '%s:%s:%s: this for loop iterates a glob directly; a glob loop that asserts no breadth reads an empty root as a clean tree — fill an array with glob_into and loop over that\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    "${GLOB_ARRAY_WHAT}")
      printf '%s:%s:%s: this array assignment expands a glob directly; an array filled without asserting its size reads an empty root as a clean tree — fill it with glob_into, passing each pattern as a quoted string\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    "${FILTER_LOOP_WHAT}")
      printf '%s:%s:%s: this loop reads a filter variable directly; that re-applies the filter test outside filter_into, and whether it runs over the already-narrowed selection or a set filter_into never narrowed cannot be told apart here — narrow the scan set with filter_into, which asserts the selection is not empty\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    "${FILTER_FUNC_WHAT}")
      printf '%s:%s:%s: this filter read sits in a function a loop calls; the loop consumes the read as if it were written inline, and whether it runs over the already-narrowed selection or a set filter_into never narrowed cannot be told apart here — narrow the scan set with filter_into, which asserts the selection is not empty\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    "${FILTER_MISSING_WHAT}")
      printf '%s:%s:%s: this script reads a filter variable but never calls filter_into; a selection whose size is asserted nowhere reads an empty result as a clean tree\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    "${FILTER_ALIAS_WHAT}")
      printf '%s:%s:%s: this assignment copies a filter value to another name; every arm of the filter rule keys on the name being read, so the copy makes the read invisible while leaving the selection unasserted — pass the filter to filter_into and read the selection it returns\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    "${PRODUCER_ALIAS_WHAT}")
      printf '%s:%s:%s: this assignment copies a producer name to a variable; the command word at the use site is then a value, so no single pass can tell what command runs there — hand the producer to enumerate_into directly, or wrap it in a function the helper is given by name\n' \
        "${f}" "${line}" "${col}" >&2
      ;;
    *)
      printf '%s:%s:%s: %s runs outside enumerate_into; an enumeration that asserts no breadth reads an empty scan as a clean tree\n' \
        "${f}" "${line}" "${col}" "${what}" >&2
      ;;
    esac
    failed=$((failed + 1))
  done <<<"${records}"

  # A marker the classification never consumed protects nothing. It still
  # reads as a decision someone made about the code beneath it, so it
  # keeps asserting that decision after the site was rewritten into a
  # compliant shape, moved, or left the file — and after a marker written
  # one line too high, which is the case a per-file predicate cannot see
  # because the file does hold a site of that kind. The sibling
  # payload-source and payload-subject rules already treat their mirror
  # case as drift, so the convention is settled.
  for marker_probe in "${!COMMENT_TEXT[@]}"; do
    comment_text="${COMMENT_TEXT[${marker_probe}]}"
    trimmed="${comment_text#"${comment_text%%[![:space:]]*}"}"
    for marker_word in "${MARKER_WORDS[@]}"; do
      [[ ${trimmed} == "${marker_word}:"* ]] || continue
      [[ -n ${CONSUMED[${marker_probe}]:-} ]] && continue
      printf '%s:%s: %s marker excuses no site this rule matches; a marker protecting nothing keeps asserting a decision the lint no longer honors — move it onto the site it was written for, or delete it\n' \
        "${f}" "${marker_probe}" "${marker_word}" >&2
      orphans=$((orphans + 1))
    done
  done
done

if ((failed > 0 || orphans > 0)); then
  if ((failed > 0)); then
    printf '%d scan(s) that assert no breadth: a filesystem enumeration outside enumerate_into, a glob expanded at a for loop head or in an array assignment, or a filter variable read directly instead of through filter_into\n' "${failed}" >&2
  fi
  if ((orphans > 0)); then
    printf '%d exemption marker(s) that excuse nothing\n' "${orphans}" >&2
  fi
  exit 1
fi

# A zero tally says nothing about whether these scripts really run no
# scan at all or whether the walk above stopped recognizing producers and
# glob loops. Both print the same clean line, so the zero has to be
# stated as deliberate. LINT_ALLOW_EMPTY_SCAN is the opt-out rather than
# a new variable: this is the same shape its siblings already use — the
# scan ran, and the count of the thing being verified came back zero.
if [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]] && ((classified == 0)); then
  printf '%s: classified 0 scan site(s) across %d file(s) scanned — an unrecognized grammar reports the same clean line a scan-free tree does; set LINT_ALLOW_EMPTY_SCAN=1 if these scripts deliberately run no enumeration and no glob scan\n' \
    "${0##*/}" "${scanned}" >&2
  exit 2
fi

printf 'enumerate-helper-required: %d file(s) scanned, %d scan site(s) classified, %d exemption(s), %d orphan marker(s)\n' \
  "${scanned}" "${classified}" "${exempted}" "${orphans}"
exit 0
