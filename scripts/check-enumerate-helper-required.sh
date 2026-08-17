#!/usr/bin/env bash
# scripts/check-enumerate-helper-required.sh
#
# @description Lint: every filesystem scan in a repo script asserts its
# own breadth. An enumeration runs through `enumerate_into`
# (scripts/lib/enumerate.sh) — a producer (`find`, `git ls-files`, `git
# ls-tree`) may appear only as an argument to the helper, inside a
# function the helper is handed by name, or behind an inline
# `# enumerate-exempt: <rationale>` marker. A glob-driven scan fills its
# array through `glob_into` — neither a `for` loop at its own head nor an
# array assignment in its element list may expand a pattern, unless an
# inline `# glob-exempt: <rationale>` marker says an empty match set is
# that site's normal state. Those two are the positions a single pass
# over the tree decides; a pattern that reaches a scan by any other route
# is outside what this lint sees, and the rule is stated no wider than
# that.
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
# That is what makes both rules decidable in one pass. Associating a scan
# with a cardinality test written an arbitrary distance later is not
# something a textual rule can do; asking whether a producer is an
# argument to the helper is local to one call expression, and so is
# asking whether a `for` loop or an array assignment expands a pattern in
# its own words. Patterns handed to `glob_into` are arguments of a
# `CallExpr` — never `WordIter` items, never array elements — and reach
# it quoted, so a compliant call site cannot false-hit the glob rule
# however many metacharacters it carries.
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
# call sites plus glob loops plus glob array assignments — is itself
# asserted nonzero (unless LINT_ALLOW_EMPTY_SCAN=1). A grammar that
# silently recognized nothing would report "0 violations" and exit 0 —
# the same clean line a genuinely scan-free tree prints — leaving this
# gate off while green, which is the exact failure it exists to prevent
# one level down.
#
# Each rule owns its own marker word, and a marker excuses only the kind
# of site it names: a rationale for running a producer outside the
# enumeration helper says nothing about whether a glob's match set may
# come back empty, and the reverse holds too.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures, and
# LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose scan-site tally (or whose
# enumerated file count) comes back zero.
# Exit 0 clean, 1 on a producer outside `enumerate_into`, a `for` loop
# expanding a glob at its own head, an array assignment expanding one in
# its element list, or an exemption marker with no rationale, 2 when a
# required tool is absent, the scan set could not be enumerated (or
# classified nothing), a named path does not exist, or a file could not
# be parsed as shell.

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

# @description NUL-delimited producer for `enumerate_into`. The pathspec
# crosses `/`, so this covers `scripts/lib/` as well as the top level.
# @stdout NUL-delimited paths
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function enumerate_helper_git_sources() {
  git ls-files -z -- 'scripts/*.sh'
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
# The `what` field of a glob record, one literal per shape so the
# diagnostic names the site the reader is looking at rather than calling
# an assignment a loop. Held in variables so the jq program and the shell
# loop that keys the marker word off them cannot drift apart.
readonly GLOB_WHAT='glob loop'
readonly GLOB_ARRAY_WHAT='glob array assignment'
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

# Position 4: a `glob_into` call. Counted rather than merely ignored, so
# the nonzero tally below covers this rule as well — a walk that stopped
# recognizing the sanctioned shape would otherwise still print a clean
# line.
| [.. | objects | select(.Type == "CallExpr")
    | select(((.Args // []) | length) > 0)
    | select((.Args[0] | literal_word_text) == "glob_into")
    | "ok\t\(.Pos.Line)\t\(.Pos.Col)\t\($glob_what)"] as $glob_calls

# Position 5: a `for` whose iteration words carry a glob metacharacter in
# an unquoted literal. Only a bare `Lit` part counts: a metacharacter
# inside quotes is not a pattern, so `for x in "*"` iterates one literal
# asterisk and asserts nothing about any tree. `.Loop.Items` is empty for
# a C-style `for ((;;))`, which therefore never reaches the test.
| [.. | objects | select(.Type == "ForClause")
    | select(([(.Loop.Items // [])[]
        | (.Parts // [])[]
        | select(.Type == "Lit")
        | (.Value // "")
        | select(test("[*?[]"))] | length) > 0)
    | "bad\t\(.Pos.Line)\t\(.Pos.Col)\t\($glob_what)"] as $glob_loops

# Position 6: an array assignment whose element words carry a glob
# metacharacter in an unquoted literal. An `Assign` node carries no
# `Type` field, so it is selected by the `Array` it holds; a scalar
# assignment holds a null one. The position reported is that of the array
# expression itself, which is where the pattern is written.
#
# Only a bare `Lit` part counts, for the same reason it does at a loop
# head, and this is the restriction the whole rule rests on: `x=("*")`
# assigns one literal asterisk and asserts nothing about any tree, and a
# pattern handed to `glob_into` travels as a quoted string
# (`patterns+=("${d}/*.yml")`) to be expanded inside the helper, where
# its match set is asserted. Counting a quoted metacharacter here would
# make every compliant call site a violation of the rule it satisfies.
| [.. | objects | select(has("Array")) | select(.Array != null)
    | select(([(.Array.Elems // [])[]
        | (.Value.Parts // [])[]
        | select(.Type == "Lit")
        | (.Value // "")
        | select(test("[*?[]"))] | length) > 0)
    | "bad\t\(.Array.Pos.Line)\t\(.Array.Pos.Col)\t\($glob_array_what)"] as $glob_arrays

| ($direct + $standalone + $glob_calls + $glob_loops + $glob_arrays)[]
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
# markers treat it.
readonly MARKER_ENUMERATE='enumerate-exempt'
readonly MARKER_GLOB='glob-exempt'

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
)
readonly MARKER_BY_WHAT

scanned=0
classified=0
exempted=0
failed=0
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
    --arg glob_array_what "${GLOB_ARRAY_WHAT}" "${JQ_PROG}" <<<"${ast_json}")"; then
    printf '%s: jq failed walking the parsed syntax tree\n' "${f}" >&2
    exit 2
  fi

  # The file is read into an array once, rather than re-read through a
  # `sed | grep` pipeline per finding: under pipefail such a pipeline
  # returns grep's no-match status whether or not the reader failed, so
  # a read failure would be indistinguishable from "no marker here".
  file_lines=()
  mapfile -t file_lines <"${f}"

  while IFS=$'\t' read -r verdict line col what; do
    [[ -z ${verdict} ]] && continue
    classified=$((classified + 1))
    [[ ${verdict} == ok ]] && continue

    # The marker word follows the kind of site, so the exemption a
    # reviewer reads is the one the site was reasoned about.
    marker_word="${MARKER_BY_WHAT[${what}]:-${MARKER_ENUMERATE}}"
    marker_re="#[[:space:]]*${marker_word}:"

    # The marker may sit on the site's own line or anywhere in the
    # contiguous comment block directly above it. A rationale worth
    # reading rarely fits on one line, and a marker that only counted
    # when it landed on the last comment line would push the reason
    # away from the sentence that explains it.
    marker_text="${file_lines[line - 1]:-}"
    probe=$((line - 1))
    while ((probe >= 1)) && [[ ${file_lines[probe - 1]:-} =~ ^[[:space:]]*# ]]; do
      marker_text="${file_lines[probe - 1]}"$'\n'"${marker_text}"
      probe=$((probe - 1))
    done

    if [[ ${marker_text} =~ ${marker_re} ]]; then
      # The rationale is the remainder of the marker's own line: a
      # continuation line may carry more prose, but the marker line
      # itself has to say something.
      rationale="${marker_text#*"${marker_word}":}"
      rationale="${rationale%%$'\n'*}"
      # Trim surrounding whitespace without invoking anything.
      rationale="${rationale#"${rationale%%[![:space:]]*}"}"
      rationale="${rationale%"${rationale##*[![:space:]]}"}"
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
    *)
      printf '%s:%s:%s: %s runs outside enumerate_into; an enumeration that asserts no breadth reads an empty scan as a clean tree\n' \
        "${f}" "${line}" "${col}" "${what}" >&2
      ;;
    esac
    failed=$((failed + 1))
  done <<<"${records}"
done

if ((failed > 0)); then
  printf '%d scan(s) that assert no breadth: a filesystem enumeration outside enumerate_into, or a glob expanded at a for loop head or in an array assignment\n' "${failed}" >&2
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

printf 'enumerate-helper-required: %d file(s) scanned, %d scan site(s) classified, %d exemption(s)\n' \
  "${scanned}" "${classified}" "${exempted}"
exit 0
