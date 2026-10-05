#!/usr/bin/env bash
# scripts/check-regex-range-ascii.sh
#
# @description Lint: a bash `[[ … =~ … ]]` regex under `scripts/` or
# `tests/` must not hold a range between ASCII letters or digits (`[0-9]`,
# `[a-f]`, `[A-Za-z_]`) unless it is matched under a C locale. A range
# follows the locale's collation: under `en_US.UTF-8` `[0-9]` also matches
# digits such as `٣` and `５`, and `[a-f]` matches `é`, while the CI
# runner's `C.UTF-8` matches ASCII only. A validator written with a range
# therefore passes on a developer's machine a value CI refuses, and the
# difference is invisible to CI.
#
# A test is matched under a C locale when it sits in a function that
# declares `local LC_ALL=C` or `local LC_ALL=C.UTF-8` (`ascii_match` in
# `scripts/lib/ascii-match.sh` is one), or in a script that runs
# `export LC_ALL=C`. Otherwise the class is spelled out
# (`[0123456789]`), or the text is matched through `ascii_match`.
#
# The `=~` tests are read from the `shfmt --tojson` parse tree, and the
# operator from the source text between the two operands, since shfmt
# releases encode the operator differently; a file holding no `=~` text
# is not parsed. A regex held in a variable is
# read through the assignments to that variable in the same file,
# following variables they name, three levels deep. Not read: a regex
# that reaches the test as a function argument, from a function's output,
# or from a sourced file; a regex inside `eval` or `bash -c` text; and
# `grep`, `sed`, `awk`, `jq` and `yq` patterns.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) and TESTS_DIR_OVERRIDE
# (default: tests), and LINT_ALLOW_EMPTY_SCAN=1 for fixtures.
#
# Exits 0 when no such range is found, 1 when one is. Exits 2 when the
# check cannot run: `shfmt` or `jq` absent from PATH, a file `shfmt`
# cannot parse, or a scan set matching no file.

set -Eeuo pipefail
IFS=$'\n\t'
# Byte offsets from the parse tree index the file text, so slicing it
# must count bytes.
export LC_ALL=C
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

require_tool shfmt
require_tool jq

# @description Emit the parse-tree records of one file, tab-separated:
# `T line x_end y_pos y_end safe` for each binary test (safe is 1 inside
# a function declaring a C locale, or in a file exporting one), and
# `A name value_pos value_end` for each assignment.
# @arg $1 file path
# @exitcode 2 shfmt cannot parse the file
function records_of() {
  local -r file="$1"
  local tree
  if ! tree="$(shfmt --tojson <"${file}" 2>/dev/null)"; then
    log_err "cannot parse ${file}"
    exit 2
  fi
  jq -r '
    def c_locale: (.Value.Parts[0].Value? // "") as $v
      | .Name.Value? == "LC_ALL" and ($v == "C" or $v == "C.UTF-8");
    def assigns: (.Args[]? | select(.Name? != null)), (.Assigns[]?);
    ([ .. | objects | select(.Type? == "DeclClause" and .Variant.Value? == "export")
        | assigns | select(c_locale) ] | length > 0) as $file_safe
    | [ .. | objects | select(.Type? == "FuncDecl")
        | select([ .Body | .. | objects
                  | select(.Type? == "DeclClause" and .Variant.Value? == "local")
                  | assigns | select(c_locale) ] | length > 0)
        | [.Pos.Offset, .End.Offset] ] as $safe_spans
    | ( .. | objects | select(.Type? == "BinaryTest")
        | .Pos.Offset as $at
        | [ "T", .Pos.Line, .X.End.Offset, .Y.Pos.Offset, .Y.End.Offset,
            (if $file_safe or any($safe_spans[]; .[0] <= $at and $at < .[1])
              then 1 else 0 end) ] ),
      ( .. | objects | select(.Type? == "DeclClause" or .Type? == "CallExpr")
        | assigns | select(.Value? != null and .Value.Pos? != null)
        | [ "A", .Name.Value, .Value.Pos.Offset, .Value.End.Offset ] )
    | @tsv' <<<"${tree}"
}

# @description Print the first range between ASCII letters or digits
# inside a bracket expression of a regex text, or nothing. `[:alpha:]`
# style classes, equivalence classes and collating symbols inside a
# bracket are skipped; a backslash before `[` outside one makes it
# literal.
# @arg $1 regex text
function first_range() {
  local -r re="$1"
  local i=0 n=${#re} c j k
  while ((i < n)); do
    c="${re:i:1}"
    # shellcheck disable=SC1003 # a single backslash, which shfmt writes this way
    if [[ ${c} == '\' ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ ${c} != '[' ]]; then
      i=$((i + 1))
      continue
    fi
    j=$((i + 1))
    [[ ${re:j:1} == '^' ]] && j=$((j + 1))
    [[ ${re:j:1} == ']' ]] && j=$((j + 1))
    while ((j < n)) && [[ ${re:j:1} != ']' ]]; do
      if [[ ${re:j:2} == '[:' || ${re:j:2} == '[=' || ${re:j:2} == '[.' ]]; then
        k="${re:j+1:1}"
        j=$((j + 2))
        while ((j < n)) && [[ ${re:j:2} != "${k}]" ]]; do j=$((j + 1)); done
        j=$((j + 2))
        continue
      fi
      if [[ ${re:j+1:1} == '-' && ${re:j:1} == [[:alnum:]] && ${re:j+2:1} == [[:alnum:]] ]]; then
        printf '%s\n' "${re:j:3}"
        return 0
      fi
      j=$((j + 1))
    done
    i=$((j + 1))
  done
}

function main() {
  local -a files=()
  glob_into files 'scripts, script libraries and harnesses' \
    "${SCRIPTS_DIR}/*.sh" "${SCRIPTS_DIR}/lib/*.sh" "${TESTS_DIR}/*.sh"

  local file text records kind f2 f3 f4 f5 f6 op regex range name ref depth
  local found=0 tests=0 resolved=0 c_locale=0
  for file in "${files[@]}"; do
    # The operator is two literal bytes in the source, so a file without
    # them holds no such test and is not parsed.
    grep --quiet --fixed-strings -- '=~' "${file}" || continue
    text="$(<"${file}")"
    if ! records="$(records_of "${file}")"; then
      exit 2
    fi
    local -A values=()
    while IFS=$'\t' read -r kind f2 f3 f4 f5 f6; do
      [[ ${kind} == A ]] || continue
      values["${f2}"]+="${text:f3:f4-f3}"$'\n'
    done <<<"${records}"
    while IFS=$'\t' read -r kind f2 f3 f4 f5 f6; do
      [[ ${kind} == T ]] || continue
      op="${text:f3:f4-f3}"
      op="${op//[[:space:]]/}"
      [[ ${op} == '=~' ]] || continue
      tests=$((tests + 1))
      if ((f6)); then
        c_locale=$((c_locale + 1))
        continue
      fi
      regex="${text:f4:f5-f4}"
      range="$(first_range "${regex}")"
      ref=''
      # A regex held in a variable is read through the variable's
      # assignments in this file, and the variables those name in turn.
      local pending="${regex}" seen=' '
      for ((depth = 1; depth <= 3; depth++)); do
        [[ -z ${range} ]] || break
        local next=''
        while [[ ${pending} =~ \$\{?([A-Za-z_][A-Za-z0-9_]*) ]]; do
          name="${BASH_REMATCH[1]}"
          pending="${pending#*"${BASH_REMATCH[0]}"}"
          [[ ${seen} == *" ${name} "* ]] && continue
          seen+="${name} "
          [[ -n ${values[${name}]:-} ]] || continue
          range="$(first_range "${values[${name}]}")"
          if [[ -n ${range} ]]; then
            ref="${name}"
            break
          fi
          next+="${values[${name}]}"
        done
        pending="${next}"
      done
      [[ ${regex} =~ \$\{?[A-Za-z_] ]] && resolved=$((resolved + 1))
      [[ -n ${range} ]] || continue
      if [[ -n ${ref} ]]; then
        printf '%s:%s: regex range %s (through %s) follows the locale\n' \
          "${file}" "${f2}" "${range}" "${ref}" >&2
      else
        printf '%s:%s: regex range %s follows the locale\n' "${file}" "${f2}" "${range}" >&2
      fi
      found=$((found + 1))
    done <<<"${records}"
    unset values
  done

  if ((found)); then
    printf '\n%d regex range(s) follow the locale: under en_US.UTF-8 [0-9] also\n' "${found}" >&2
    printf 'matches digits such as U+0663 and U+FF15. Spell the class out\n' >&2
    printf '([0123456789]) or match through ascii_match (scripts/lib/ascii-match.sh).\n' >&2
    exit 1
  fi
  printf 'regex-range-ascii: ok — scanned %d file(s), %d =~ test(s), %d with a regex in a variable, %d under a C locale\n' \
    "${#files[@]}" "${tests}" "${resolved}" "${c_locale}"
}

main "$@"
