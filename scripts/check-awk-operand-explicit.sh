#!/usr/bin/env bash
# scripts/check-awk-operand-explicit.sh
#
# @description Lint: every `awk` invocation in a script under
# `scripts/` that carries a file operand must spell that operand
# `"$(awk_path "${var}")"`. `awk` reads an operand shaped
# `name=value` as a variable assignment rather than a filename; it
# scans the whole tree: the `scripts/*.sh` git pathspec crosses `/`,
# so the sourced libraries under `scripts/lib/` are in scope too. It
# then finds no file operand, reads stdin, and exits 0 having scanned
# nothing — so a relative path whose first component contains `=`
# scores as an empty file instead of failing loud.
# `scripts/lib/awk-path.sh`'s `awk_path()` closes that for a wrapped
# operand; this lint is the backstop that keeps every future `awk`
# call wrapped too, rather than trusting a one-time sweep to hold
# forever.
#
# Detection parses each script's shell syntax tree via `shfmt
# --to-json` (the same mvdan.cc/sh parser `shfmt` and `treefmt`
# already run over this repo) rather than matching text: a textual
# rule would drift the moment a script's formatting moves an operand
# onto another line, inside a multi-line awk program, or next to a
# sibling operand. The scan also recognizes `gawk`/`mawk`/`nawk`, an
# absolute or relative path ending in one of those basenames (e.g.
# `/usr/bin/awk`), a `command`-prefixed invocation, and a
# statically-quoted `"awk"`/`'awk'` word — not just the bare `awk`
# literal — since a future call site is under no obligation to spell
# the command the same way every existing one does.
#
# For every such call, the argument list is walked following awk's
# own flags-then-program-then-operands grammar: `-v`, `-F`,
# `-f`/`--file`, `--field-separator`, `--assign`, `--source`, `--`,
# and their attached forms (`-F'\t'`, `--field-separator=x`,
# `-fprog.awk`, `--file=prog.awk`) are all recognized as flags while
# no program has been supplied yet. `-f`, `--file`, and `--source`
# supply the program text (a repeated one concatenates, which is
# legal), so any of them marks the program as already established
# without ending flag recognition — a legally-repeated
# `-f a.awk -f b.awk` is not misread as two operands; `--field-separator`
# and `--assign` keep being read as flags too once a program is
# established. `-v`, `-F`, and `--` behave differently once a program
# is already established: gawk (measured directly) then reads any of
# the three as an ordinary filename rather than as a flag, bare or
# attached, so the walk folds a further `-v`/`-F`/`--` back into "this
# is an operand" instead of treating it as one. Only the first
# non-flag word establishes the inline program (when none of
# `-f`/`--file`/`--source` already has); every non-flag word after
# that is an operand. `-f`/`--file`'s own value and the program text
# itself are excluded from the operand list, since neither was ever a
# file operand. Each surviving operand must be exactly one
# double-quoted word wrapping a single command substitution that
# calls `awk_path` — anything else is a violation.
#
# Not operands, and therefore never reach the walk above: stdin
# redirections and here-strings (a redirection attaches to the
# enclosing statement, not the command's argument list, so an `awk`
# call fed one has zero operand arguments to inspect) and pipeline
# input (same — the producer feeds stdin, not an argument).
#
# The total operand count checked across the run is itself asserted
# nonzero (unless LINT_ALLOW_EMPTY_SCAN=1): a parser regression that
# silently drops every operand from its accounting — e.g. an
# attached-flag word reclassified as a no-op instead of as the
# operand-bearing word it actually is — would otherwise still print a
# clean "0 violations" and exit 0. See the assertion below for why
# LINT_ALLOW_EMPTY_SCAN, rather than a dedicated variable, is the
# right opt-out.
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures,
# and LINT_ALLOW_EMPTY_SCAN=1 to accept a run whose operand tally (or
# whose enumerated file count) comes back zero.
# Exit 0 clean, 1 on any unwrapped operand, 2 when a required tool is
# absent, the scan set could not be enumerated (or came back with a
# zero operand tally), a named path does not exist, or a file could
# not be parsed as shell.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"

# A missing `shfmt` or `jq` must be diagnosed as itself, not folded into
# the per-file "could not parse" message below: that message is reserved
# for a file that genuinely fails to parse as shell once both tools are
# known to be present.
require_tool shfmt
require_tool jq

# @description NUL-delimited scripts/*.sh producer for `enumerate_into`.
# @stdout NUL-delimited paths
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function awk_operand_explicit_git_sources() {
  git ls-files -z -- 'scripts/*.sh'
}

paths=()
if [[ -n ${PATHS_OVERRIDE:-} ]]; then
  while IFS= read -r p; do
    [[ -z ${p} ]] && continue
    paths+=("${p}")
  done <<<"${PATHS_OVERRIDE}"
else
  enumerate_into paths 'git ls-files' awk_operand_explicit_git_sources
fi

# The jq program below walks one file's shfmt --to-json syntax tree
# per run (--to-json accepts only stdin, one document per
# invocation). It emits one "<0|1>\t<line>\t<col>" record per operand
# found on every `awk` CallExpr: 1 when that operand is already
# wrapped in `awk_path`, 0 when it is not.
#
# `classify_operands` is a hand-rolled recursive walk rather than a
# `reduce`: a flag like `-v` or `-f` consumes the *next* array
# element as its value, which `reduce`'s single-element-at-a-time
# iteration has no lookahead to express. `flag_class` tells a bare
# flag word (its value is the next array element, e.g. `-v` then
# `mode="${mode}"`) apart from an attached one (the value is another
# part of the *same* word, e.g. `-F'\t'`, or trails a `=` in the same
# literal, e.g. `--field-separator=x`): a word that is a single `Lit`
# part exactly matching the flag name is bare; anything else that
# merely starts with the flag name is attached.
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly JQ_PROG='
# The known awk option names. A word is a "bare" instance of one of
# these only when the word is exactly one `Lit` part matching the name
# verbatim (e.g. the two-word form `-v` then `mode=1`); any other word
# that merely starts with the name (a `Lit`-plus-more word like
# `-F"\t"`, or a longer literal like `-fprog.awk` or
# `--field-separator=x`) is an "attached" instance carrying its own
# value, and consumes nothing further.
def flag_class:
  . as $w
  | (($w.Parts // [])[0]) as $first
  | if ($first == null or $first.Type != "Lit") then null
    else
      ($first.Value) as $lit
      | if ($lit | startswith("-") | not) then null
        elif $lit == "--" then {name: "--", consumes: false}
        else
          (["-v", "-F", "-f", "--file", "--field-separator", "--assign", "--source"]) as $flags
          | ($flags | map(select(. == $lit))) as $exact
          | if ($exact | length) > 0 then
              if (($w.Parts // []) | length) == 1
              then {name: $exact[0], consumes: true}
              else {name: $exact[0], consumes: false}
              end
            else
              # `. as $fl` rebinds `.` inside the `select` predicate to
              # each candidate flag name in turn, so `startswith($fl)`
              # tests the flag name against `$lit` — not `$lit` against
              # itself, which is what an unbound `startswith(.)` here
              # would silently always satisfy.
              ($flags | map(select(. as $fl | $lit != $fl and ($lit | startswith($fl))))) as $prefix
              | if ($prefix | length) > 0
                then {name: $prefix[0], consumes: false}
                else {name: "unknown", consumes: false}
                end
            end
        end
    end;

# Walks one awk calls argument words (everything after the command
# word itself) into its list of file operands. `-f`/`--file`/`--source`
# each supply program text — a repeated one legally concatenates onto
# the program, so any of them marks the program "already supplied"
# without ending flag recognition: the next word is still checked
# against `flag_class` before falling through to "this is an operand".
# Only once a word is neither `--` nor a recognized flag does the walk
# decide it: the first such word is the inline program if none of
# `-f`/`--file`/`--source` supplied one yet, and every one after that
# is an operand.
#
# `--`, `-v`, and `-F` are special-cased further, because their
# meaning depends on whether the program has already been supplied:
# while flags are still being read (`prog` false), each behaves as
# documented — `--` ends option parsing, `-v`/`-F` take a value. Once
# the program is already established, gawk (measured directly: a
# post-program `-v`, bare or attached, fails with `cannot open file
# '-v'`; likewise `-F`) reads a further `--`/`-v`/`-F` as an ordinary
# filename instead of as a flag — `awk-path.sh`s header documents the
# `--` half of this, and it holds identically for `-v`/`-F`. `-f`,
# `--file`, and `--source` are not folded the same way: unlike `-v`/
# `-F`, a repeated one legally keeps supplying program text (see
# above), so they stay flags with `prog` already true.
def classify_operands:
  def go(arr; eo; prog; ops):
    if (arr | length) == 0 then ops
    else
      (arr[0]) as $w
      | (if eo then null else ($w | flag_class) end) as $cls0
      | (if ($cls0 != null and prog and
          ($cls0.name == "--" or $cls0.name == "-v" or $cls0.name == "-F"))
        then null else $cls0 end) as $cls
      | if $cls == null then
          if prog
          then go(arr[1:]; eo; prog; ops + [$w])
          else go(arr[1:]; eo; true; ops)
          end
        elif $cls.name == "--" then
          go(arr[1:]; true; prog; ops)
        else
          (if ($cls.name == "-f" or $cls.name == "--file" or $cls.name == "--source")
            then true else prog end) as $newprog
          | (if $cls.consumes then arr[2:] else arr[1:] end) as $rest
          | go($rest; eo; $newprog; ops)
        end
    end;
  go(.; false; false; []);

def is_wrapped:
  (.Parts // []) as $p
  | if ($p | length) != 1 then false
    elif ($p[0].Type != "DblQuoted") then false
    else
      ($p[0].Parts // []) as $dp
      | if ($dp | length) != 1 then false
        elif ($dp[0].Type != "CmdSubst") then false
        else
          ($dp[0].Stmts // []) as $st
          | if ($st | length) != 1 then false
            else
              ($st[0].Cmd // {}) as $cmd
              | if ($cmd.Type != "CallExpr") then false
                else
                  ($cmd.Args // []) as $ca
                  | if ($ca | length) < 1 then false
                    else
                      (($ca[0].Parts // []) | .[0]) as $fp
                      | ($fp != null and $fp.Type == "Lit" and $fp.Value == "awk_path")
                    end
                end
            end
        end
    end;

# Extracts a word as plain text only when it is unambiguously static:
# a bare literal (`awk`), a shell-single-quoted literal, or a
# double-quoted literal with no interpolation (`"awk"`). Anything that
# involves a parameter expansion, command substitution, or more than
# one part returns null rather than a guessed value, so a variable that
# happens to hold the text "awk" at runtime is never mistaken for the
# command word.
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

# True for a word naming an awk implementation directly (`awk`, `gawk`,
# `mawk`, `nawk`) or via a path ending in one of those basenames (e.g.
# `/usr/bin/awk`), however the word is spelled per `literal_word_text`.
def is_awk_word:
  literal_word_text as $t
  | $t != null and (($t | split("/") | last) as $base
      | $base == "awk" or $base == "gawk" or $base == "mawk" or $base == "nawk");

# Index of the awk word itself within a CallExpr Args array: 0
# normally, or 1 when Args[0] is a literal `command` prefix
# (`command awk ...`).
def prog_index:
  ((.Args[0] // {}) | literal_word_text) as $t
  | if $t == "command" then 1 else 0 end;

def is_awk_call:
  (.Type == "CallExpr")
  and (((.Args // []) | length) > prog_index)
  and ((.Args[prog_index]) | is_awk_word);

[.. | objects | select(is_awk_call)] as $calls
| $calls[]
| (prog_index) as $pi
| (.Args[($pi + 1):] | classify_operands) as $ops
| $ops[]
| "\(if (is_wrapped) then 1 else 0 end)\t\(.Pos.Line)\t\(.Pos.Col)"
'

scanned=0
checked=0
failed=0
for f in "${paths[@]}"; do
  # A path `git ls-files` enumerated always exists; a path named by
  # `PATHS_OVERRIDE` is operator input, and one naming a file that is
  # not there is a could-not-run, not a file to quietly drop from the
  # scan set.
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

  while IFS=$'\t' read -r wrapped line col; do
    [[ -z ${wrapped} ]] && continue
    checked=$((checked + 1))
    if [[ ${wrapped} == 0 ]]; then
      # shellcheck disable=SC2016 # literal $(awk_path ...) in human-readable prose
      printf '%s:%s:%s: awk file operand not spelled "$(awk_path ...)"\n' \
        "${f}" "${line}" "${col}" >&2
      failed=$((failed + 1))
    fi
  done <<<"${records}"
done

if ((failed > 0)); then
  printf '%d awk file operand(s) not wrapped in awk_path\n' "${failed}" >&2
  exit 1
fi

# `checked` coming back 0 says nothing about whether the scripts really
# carry no awk operand or whether the walk above silently misclassified
# every one of them as a flag value or a program instead — a
# misclassification that "0 operand(s) checked, 0 violations" hides,
# because that is the same line a genuinely clean run prints.
# LINT_ALLOW_EMPTY_SCAN is the
# opt-out rather than a dedicated variable: `check-doc-anchors.sh`
# already uses this same variable to gate two different zero-breadth
# conditions in one script (0 files scanned, then 0 anchor links found
# among files that were), so a zero operand tally is a third instance
# of the identical shape — enumeration succeeded, but the count of the
# thing this lint verifies came back zero — and reuses the same signal
# rather than minting a new one for what is the same kind of "prove
# this is deliberate" gate.
if [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]] && ((checked == 0)); then
  printf '%s: checked 0 awk file operand(s) across %d file(s) scanned — an unread tree reports the same clean line a genuinely operand-free one does; set LINT_ALLOW_EMPTY_SCAN=1 if these scripts deliberately carry no awk file operand\n' \
    "${0##*/}" "${scanned}" >&2
  exit 2
fi

printf 'awk-operand-explicit: %d file(s) scanned, %d operand(s) checked, 0 violations\n' \
  "${scanned}" "${checked}"
exit 0
