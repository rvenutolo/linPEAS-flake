#!/usr/bin/env bash
# scripts/check-tool-guarded.sh
#
# @description Lint: every third-party tool a script under `scripts/`
# invokes must be guarded somewhere in that same script. A guard is
# `require_tool <tool>`, a `command -v <tool>` availability test, or a
# library helper that guards the tool on its caller's behalf.
#
# An unguarded tool does not fail loudly. It fails as whatever the
# surrounding code does with a non-zero status, and every one of those
# readings is wrong:
#
#   * A shape probe written as `<tool> ... || die` reports the payload as
#     malformed. The operator opens a file that is intact and looks for a
#     field that is present.
#   * A guard that treats success as the violation — `if <tool> ...; then
#     report` — scores every input clean, because an absent tool cannot
#     succeed. The check exits 0 having read nothing, which is the only
#     failure mode here that no caller can see.
#   * An enumeration ending in `|| true` comes back empty, and a lint that
#     asserts over an empty set asserts nothing.
#   * An unchecked command substitution ends the run under the tool's own
#     status — 127 for an absent one — which the exit-code convention
#     does not catalogue.
#
# The convention this protects: 2 means the check could not run, 1 means
# it ran and found a violation, 0 means it ran and found none. A missing
# binary is a could-not-run in every case, and `require_tool` is what
# says so.
#
# Scope is tools a shell can genuinely lack. POSIX utilities and
# coreutils staples are assumed present: guarding `grep` in every script
# that greps would cost a hundred lines to describe an environment that
# does not occur, and a rule nobody believes is a rule that gets
# exempted.
#
# The rule is presence, not position. A parse tree reports where a word
# was written, and in shell that is not when it runs: nearly every script
# here defines its functions above the `main` that calls them, so a tool
# invoked at line 100 inside a function routinely executes after a guard
# written at line 700. Ordering those two correctly needs a call graph,
# and comparing the line numbers instead reports the tree's ordinary
# layout as a defect. What is checkable without one — and what the nine
# faults this rule was written for all violate — is whether the script
# guards the tool at all.
#
# Detection reads command words from `shfmt --tojson` rather than
# matching text. A tool name occurs in comments, in message strings, and
# in `@description` prose, and none of those is an invocation; a `||`
# inside a `sed` or `awk` program text reads as shell control flow to a
# line-oriented scan. The parser knows which words are commands and a
# regex does not.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) and
# LINT_ALLOW_EMPTY_SCAN=1 for fixtures.
#
# Exits 0 when every invocation is guarded, 1 when one is not. Exits 2
# when the check cannot run: `shfmt` or `jq` absent from PATH, a script
# `shfmt` cannot parse, or a scan set matching no script.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"

# This lint reads its scan set through both of these, so it is subject to
# its own rule. A rule its own enforcer violates is a rule with an
# exemption nobody wrote down.
require_tool shfmt
require_tool jq

# Tools this rule covers: third-party binaries a shell can be missing.
readonly -a TOOLS=(
  actionlint check-jsonschema cosign curl docker gh jq just nix
  shellcheck shfmt treefmt yq
)

# Library helpers that call `require_tool` themselves, keyed by the tool
# they guard. A caller of one of these is covered without repeating the
# guard: `require_json_payload` gates every payload read in this tree and
# calls `require_tool jq` before its first read, so demanding a second,
# redundant guard at each call site would make the shared helper's own
# guarantee look untrusted.
declare -rA HELPER_GUARDS=(
  ["require_json_payload"]="jq"
)

# @description Emit one `line<TAB>word<TAB>arg1<TAB>arg2` record per
# command invocation in a script, reading command words from the parse
# tree so that a name in a comment or a string is not mistaken for a
# call.
#
# Absent arguments are emitted as `-` rather than as empty fields. A tab
# is IFS whitespace, so a run of them collapses and a record with an
# empty middle field would be read one field short, silently shifting
# every value after it.
#
# @arg $1 script path
# @exitcode 2 shfmt cannot parse the script
function invocations_of() {
  local -r file="$1"
  local tree
  if ! tree="$(shfmt --tojson <"${file}" 2>/dev/null)"; then
    log_err "cannot parse ${file}"
    exit 2
  fi
  # `--to-json` reads stdin only, so the file arrives by redirect and the
  # diagnostic above is what names it.
  jq -r '
    [ .. | objects
      | select(.Type == "CallExpr")
      | select((.Args | length) > 0)
      | { l: (.Args[0].Parts[0].ValuePos.Line? // 0),
          w: (.Args[0].Parts[0].Value? // ""),
          a1: (.Args[1].Parts[0].Value? // "-"),
          a2: (.Args[2].Parts[0].Value? // "-") } ]
    | .[]
    | select(.w != "")
    | [ .l, .w, (.a1 | if . == "" then "-" else . end),
        (.a2 | if . == "" then "-" else . end) ]
    | @tsv' <<<"${tree}"
}

function main() {
  local -a scripts=()
  glob_into scripts 'scripts' "${SCRIPTS_DIR}"/*.sh

  local file line word a1 a2 tool records
  local failed=0 invocations=0 guarded_scripts=0
  local -A tally=()

  for file in "${scripts[@]}"; do
    # first_use holds the earliest line each tool was invoked on, used
    # only to point the diagnostic at a real invocation. guard_at records
    # that a guard exists; its line is not compared against first_use,
    # for the reason the header gives.
    local -A first_use=() guard_at=()
    # Captured with its status checked rather than read through a process
    # substitution, whose subshell keeps its own exit to itself: a parse
    # failure would leave this loop reading nothing and the script would
    # score clean — the same silent-pass shape this rule exists to catch,
    # reproduced inside its own enforcer.
    if ! records="$(invocations_of "${file}")"; then
      exit 2
    fi
    while IFS=$'\t' read -r line word a1 a2; do
      [[ -n ${word} ]] || continue
      case "${word}" in
      require_tool)
        [[ ${a1} != '-' ]] && : "${guard_at[${a1}]:=${line}}"
        ;;
      command)
        [[ ${a1} == '-v' && ${a2} != '-' ]] && : "${guard_at[${a2}]:=${line}}"
        ;;
      esac
      if [[ -n ${HELPER_GUARDS[${word}]:-} ]]; then
        : "${guard_at[${HELPER_GUARDS[${word}]}]:=${line}}"
      fi
      for tool in "${TOOLS[@]}"; do
        [[ ${word} == "${tool}" ]] || continue
        : "${first_use[${tool}]:=${line}}"
      done
    done <<<"${records}"

    local script_ok=1
    for tool in "${!first_use[@]}"; do
      invocations=$((invocations + 1))
      tally["${tool}"]=$((${tally[${tool}]:-0} + 1))
      local used="${first_use[${tool}]}"
      if [[ -z ${guard_at[${tool}]:-} ]]; then
        printf '%s: invokes %s (line %s) but never guards it\n' \
          "${file}" "${tool}" "${used}" >&2
        failed=1
        script_ok=0
      fi
    done
    if ((${#first_use[@]} > 0)) && ((script_ok)); then
      guarded_scripts=$((guarded_scripts + 1))
    fi
    unset first_use guard_at
  done

  if ((failed)); then
    printf '\nAn absent tool is a could-not-run. Unguarded, it becomes whatever\n' >&2
    printf 'the surrounding code makes of a non-zero status — a malformed-input\n' >&2
    printf 'verdict, a clean pass over input nobody read, or an exit code the\n' >&2
    printf 'convention does not catalogue. Add require_tool <tool> ahead of use.\n' >&2
    exit 1
  fi

  # The per-tool breakdown is what makes two clean runs distinguishable:
  # a summary that reports only totals reads the same whether the scan
  # found one guarded `jq` or one guarded `yq`, and a harness cannot then
  # tell its own scenarios apart. Sorted under LC_ALL=C so the rendering
  # is a property of the scan rather than of the machine's collation.
  local -a breakdown=()
  for tool in $(printf '%s\n' "${!tally[@]}" | LC_ALL=C sort); do
    breakdown+=("${tool}=${tally[${tool}]}")
  done
  printf 'tool-guarded: ok — scanned %d script(s), %d guarded invocation(s) across %d script(s) [%s]\n' \
    "${#scripts[@]}" "${invocations}" "${guarded_scripts}" \
    "$(
      IFS=' '
      printf '%s' "${breakdown[*]}"
    )"
}

main "$@"
