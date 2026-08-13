#!/usr/bin/env bash
# scripts/check-enumerate-helper-required.sh
#
# @description Lint: every filesystem enumeration in a repo script runs
# through `enumerate_into` (scripts/lib/enumerate.sh). A producer —
# `find`, `git ls-files`, `git ls-tree` — may appear only as an argument
# to the helper, inside a function the helper is handed by name, or
# behind an inline `# enumerate-exempt: <rationale>` marker.
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
# That is what makes this rule decidable in one pass. Associating an
# enumeration with a cardinality test written an arbitrary distance
# later is not something a textual rule can do; asking whether a
# producer is an argument to the helper is local to one call expression.
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
# The count of producer calls classified is itself asserted nonzero
# (unless LINT_ALLOW_EMPTY_SCAN=1). A grammar that silently recognized
# no producers would report "0 violations" and exit 0 — the same clean
# line a genuinely producer-free tree prints — leaving this gate off
# while green, which is the exact failure it exists to prevent one level
# down.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures, and
# LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose producer tally (or whose
# enumerated file count) comes back zero.
# Exit 0 clean, 1 on a producer outside the helper or an exemption
# marker with no rationale, 2 when a required tool is absent, the scan
# set could not be enumerated (or classified nothing), a named path does
# not exist, or a file could not be parsed as shell.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"

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
# one `<ok|bad>\t<line>\t<col>\t<producer>` record per producer call.
#
# Three positions are recognized, and each is counted:
#   ok  — the producer's words are arguments of an `enumerate_into` call
#   ok  — the producer runs inside a function whose name that same file
#         hands to `enumerate_into`
#   bad — anywhere else
#
# A producer passed directly to the helper is NOT its own command node:
# `enumerate_into arr label git ls-files -z` parses as one call whose
# argument words happen to be `git`, `ls-files`, … So the direct form is
# found by inspecting the helper's own arguments, and the free-standing
# form by looking for a producer command node. The two cannot
# double-count each other, because a word is either an argument of the
# helper call or the head of its own.
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

| ($direct + $standalone)[]
'

# An exemption marker on the producer's own line or the line above it.
# The marker must open the comment, so prose naming it exempts nothing,
# and the rationale must be non-empty — an empty one is drift, not an
# exemption, exactly as the sibling exit-code and patch-tag markers
# treat it.
readonly MARKER='#[[:space:]]*enumerate-exempt:'

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
  if ! records="$(jq --raw-output "${JQ_PROG}" <<<"${ast_json}")"; then
    printf '%s: jq failed walking the parsed syntax tree\n' "${f}" >&2
    exit 2
  fi

  # The file is read into an array once, rather than re-read through a
  # `sed | grep` pipeline per finding: under pipefail such a pipeline
  # returns grep's no-match status whether or not the reader failed, so
  # a read failure would be indistinguishable from "no marker here".
  file_lines=()
  mapfile -t file_lines <"${f}"

  while IFS=$'\t' read -r verdict line col producer; do
    [[ -z ${verdict} ]] && continue
    classified=$((classified + 1))
    [[ ${verdict} == ok ]] && continue

    # The marker may sit on the producer's own line or anywhere in the
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

    if [[ ${marker_text} =~ ${MARKER} ]]; then
      # The rationale is the remainder of the marker's own line: a
      # continuation line may carry more prose, but the marker line
      # itself has to say something.
      rationale="${marker_text#*enumerate-exempt:}"
      rationale="${rationale%%$'\n'*}"
      # Trim surrounding whitespace without invoking anything.
      rationale="${rationale#"${rationale%%[![:space:]]*}"}"
      rationale="${rationale%"${rationale##*[![:space:]]}"}"
      if [[ -z ${rationale} ]]; then
        printf '%s:%s:%s: enumerate-exempt marker carries no rationale; %s stays a hit until the marker says why the helper is wrong here\n' \
          "${f}" "${line}" "${col}" "${producer}" >&2
        failed=$((failed + 1))
      else
        exempted=$((exempted + 1))
      fi
      continue
    fi

    printf '%s:%s:%s: %s runs outside enumerate_into; an enumeration that asserts no breadth reads an empty scan as a clean tree\n' \
      "${f}" "${line}" "${col}" "${producer}" >&2
    failed=$((failed + 1))
  done <<<"${records}"
done

if ((failed > 0)); then
  printf '%d filesystem enumeration(s) outside enumerate_into\n' "${failed}" >&2
  exit 1
fi

# A zero tally says nothing about whether these scripts really run no
# enumeration or whether the walk above stopped recognizing producers.
# Both print the same clean line, so the zero has to be stated as
# deliberate. LINT_ALLOW_EMPTY_SCAN is the opt-out rather than a new
# variable: this is the same shape its siblings already use — the scan
# ran, and the count of the thing being verified came back zero.
if [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]] && ((classified == 0)); then
  printf '%s: classified 0 producer call(s) across %d file(s) scanned — an unrecognized producer grammar reports the same clean line an enumeration-free tree does; set LINT_ALLOW_EMPTY_SCAN=1 if these scripts deliberately run no enumeration\n' \
    "${0##*/}" "${scanned}" >&2
  exit 2
fi

printf 'enumerate-helper-required: %d file(s) scanned, %d producer call(s) classified, %d exemption(s)\n' \
  "${scanned}" "${classified}" "${exempted}"
exit 0
