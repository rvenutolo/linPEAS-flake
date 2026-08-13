#!/usr/bin/env bash
# scripts/check-awk-operand-explicit.sh
#
# @description Lint: every `awk` invocation in scripts/*.sh that
# carries a file operand must spell that operand
# `"$(awk_path "${var}")"`. `awk` reads an operand shaped
# `name=value` as a variable assignment rather than a filename; it
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
# sibling operand. For every `awk` CallExpr, the argument list is
# walked following awk's own flags-then-program-then-operands
# grammar (`-v`, `-F`, `-f`/`--file`, `--field-separator`,
# `--assign`, `--source`, `--`, and their attached forms) to find the
# program argument and every argument after it; `-f`/`--file`'s own
# value and the inline program text are excluded from the operand
# list, since neither was ever a file operand. Each surviving operand
# must be exactly one double-quoted word wrapping a single command
# substitution that calls `awk_path` — anything else is a violation.
#
# Not operands, and therefore never reach the walk above: stdin
# redirections and here-strings (a redirection attaches to the
# enclosing statement, not the command's argument list, so an `awk`
# call fed one has zero operand arguments to inspect) and pipeline
# input (same — the producer feeds stdin, not an argument).
#
# Honors PATHS_OVERRIDE (newline-separated file list) for fixtures,
# and LINT_ALLOW_EMPTY_SCAN=1 to accept an empty scan set.
# Exit 0 clean, 1 on any unwrapped operand, 2 when the scan set could
# not be enumerated or a file could not be parsed.

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"

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
              ($flags | map(select($lit != . and ($lit | startswith(.))))) as $prefix
              | if ($prefix | length) > 0
                then {name: $prefix[0], consumes: false}
                else {name: "unknown", consumes: false}
                end
            end
        end
    end;

def classify_operands:
  def go(arr; eo; prog; ops):
    if (arr | length) == 0 then ops
    else
      (arr[0]) as $w
      | (if (eo or prog) then null else ($w | flag_class) end) as $cls
      | if $cls == null then
          if prog
          then go(arr[1:]; eo; prog; ops + [$w])
          else go(arr[1:]; eo; true; ops)
          end
        elif $cls.name == "--" then
          go(arr[1:]; true; prog; ops)
        else
          (if ($cls.name == "-f" or $cls.name == "--file") then true else prog end) as $newprog
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

def is_awk_call:
  (.Type == "CallExpr")
  and (((.Args // []) | length) > 0)
  and (((((.Args[0].Parts // []) | .[0])) as $fp | $fp != null and $fp.Type == "Lit" and $fp.Value == "awk"))
  and (((.Args[0].Parts // []) | length) == 1);

[.. | objects | select(is_awk_call)] as $calls
| $calls[]
| (.Args[1:] | classify_operands) as $ops
| $ops[]
| "\(if (is_wrapped) then 1 else 0 end)\t\(.Pos.Line)\t\(.Pos.Col)"
'

scanned=0
checked=0
failed=0
for f in "${paths[@]}"; do
  [[ -f ${f} ]] || continue
  scanned=$((scanned + 1))

  ast_json=""
  if ! ast_json="$(shfmt --to-json <"${f}" 2>/dev/null)"; then
    printf '%s: could not parse as shell for AST inspection\n' "${f}" >&2
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

printf 'awk-operand-explicit: %d file(s) scanned, %d operand(s) checked, 0 violations\n' \
  "${scanned}" "${checked}"
exit 0
