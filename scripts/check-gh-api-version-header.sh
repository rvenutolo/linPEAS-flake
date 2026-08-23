#!/usr/bin/env bash
# scripts/check-gh-api-version-header.sh
#
# @description Lint: every `gh api` invocation and every `api.github.com`
# request in scripts/*.sh passes an explicit
# `X-GitHub-Api-Version: <date>` header.

# Lint: assert every `gh api` invocation and every `api.github.com`
# request in scripts/*.sh passes an explicit
# `X-GitHub-Api-Version: <date>` header.
#
# Without the header, GitHub treats the client as unversioned and may
# auto-promote it to a future API version whose response shape differs
# from what the script parses. Pre-commit + CI run this lint so any
# new offender trips before merging.
#
# --- Why an AST, not a text scan ------------------------------------------
#
# Command words come from `shfmt --tojson`, which separates an invocation
# from a string that happens to spell one. A text matcher gets both
# directions wrong, and both directions cost something:
#
#   * A diagnostic naming the tool it is reporting on — `log_err "cannot
#     list rulesets: gh api failed"` — is read as a call that must carry
#     the header. The workaround is to stop naming the command that
#     failed, which is the one thing an operator reading the message
#     needs.
#   * An invocation inside a command substitution is invisible: a matcher
#     anchoring `gh` to line start or whitespace never sees the `(` in
#     `$(gh api ...)`. That is not a corner case here — most call sites in
#     this tree are written that way, and a scan of `scripts/` finds three
#     of twelve by text and all twelve by parse tree.
#
# The parser also settles the continuation question for free: a statement
# split across backslash-continued lines is one `CallExpr` node, so
# nothing has to re-join lines to see the header sitting three lines below
# the command word.
#
# --- What counts as a call ------------------------------------------------
#
#   * command word `gh` whose first argument is `api`
#   * command word `curl` or `wget` with a literal argument naming
#     `api.github.com`
#
# The second arm is scoped to request-issuing command words rather than to
# any argument anywhere: a rule reading `api.github.com` out of every
# command's arguments would report the host named in someone's error
# message, which is the same string-for-invocation mistake one level over.
#
# --- What counts as the header --------------------------------------------
#
# A literal `X-GitHub-Api-Version` among the invocation's arguments, or a
# parameter expansion of a variable this file assigns a literal spelling
# it. Three call sites in this tree pass the header as
# `--header "${GH_API_VERSION_HEADER}"`, and a rule reading only literal
# arguments would report a header that is demonstrably there.
#
# --- Declared blind spot --------------------------------------------------
#
# A command word that is itself an expansion — `"${gh_bin}" api ...` —
# names no command the parser can resolve, so this rule cannot hold it to
# anything. Those are counted and named in the summary rather than passed
# over in silence: a scan that cannot see a shape should say how much of
# the tree it could not see.
#
# Honors SCRIPTS_DIR_OVERRIDE for the test harness (defaults to
# `scripts`, repo-root-relative) and LINT_ALLOW_EMPTY_SCAN=1 for fixtures.
#
# Exits 0 when every call carries the header, 1 on any offender, 2 when
# the scan could not run: `shfmt` or `jq` absent, a script `shfmt` cannot
# parse, or a missing scripts directory. A directory that was never
# scanned holds no offenders, so it must not borrow the violation code.
#
# payload-subject-exempt: matches only because it names the literal string "gh api" as the pattern it reports on — it issues no API call, and its input is this repo's own shell source read through shfmt, whose unparsable case it already reports as a could-not-run

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
# the repo's own tool-guard rule.
require_tool shfmt
require_tool jq

if [[ ! -d ${SCRIPTS_DIR} ]]; then
  printf 'scripts dir not found: %s\n' "${SCRIPTS_DIR}" >&2
  exit 2
fi

# One record per interesting node, as `kind<TAB>line<TAB>header<TAB>preview`.
# Every field is populated — absent ones as `-` — because a tab is IFS
# whitespace, so a run of them collapses and a record with an empty middle
# field is read one field short, shifting every value after it. The
# free-text preview is last for the same reason, and it opens with the
# command word, so no separate field carries it.
#
# shellcheck disable=SC2016 # jq program text: $words and friends are jq bindings, not shell expansions
readonly JQ_PROGRAM='
def literals: [ .. | objects | .Value? | select(type == "string") ];
def paramnames: [ .. | objects | select(.Type? == "ParamExp")
  | .Param.Value? | select(type == "string") ];
def has_header: any(test("X-GitHub-Api-Version"));

# Variables assigned a literal spelling the version header. An Assign node
# is the one shape carrying both a Name object and a Value.
[ .. | objects
  | select((.Name? | type) == "object")
  | select((.Name.Value? | type) == "string")
  | select(has("Value"))
  | select(.Value | literals | has_header)
  | .Name.Value ] as $header_vars
| [ .. | objects
    | select(.Type? == "CallExpr")
    | select((.Args | length) > 0) ] as $calls
| ( [ $calls[]
      | select((.Args[0].Parts[0].Value? | type) != "string")
      | [ "unresolved", (.Args[0].Pos.Line), "-", "-" ] ] )
+ ( [ $calls[]
      | . as $call
      | (.Args[0].Parts[0].Value?) as $word
      | select(($word | type) == "string")
      | (literals) as $words
      | select(
          (($word == "gh")
            and (((.Args[1]? // {}) | literals | first) == "api"))
          or ((($word == "curl") or ($word == "wget"))
              and ($words | any(test("api\\.github\\.com"))))
        )
      | (($words | has_header)
          or (($call | paramnames)
              | any(. as $name | $header_vars | index($name)))) as $carried
      | [ "call",
          (.Args[0].Pos.Line),
          (if $carried then "header" else "missing" end),
          ($words | join(" ")) ] ] )
+ ( [ .. | objects
      | select(has("Hash"))
      | select((.Text? | type) == "string")
      | select(.Text | test("gh[ \t]+api|api\\.github\\.com"))
      | [ "comment", .Hash.Line, "-", "-" ] ] )
| .[] | @tsv
'

# Scope tallies behind the clean-path summary: how many files the glob
# reached, how many call sites were held to the header rule, how many API
# mentions were set aside because they sit in a comment, and which files
# hold a command word the parser cannot resolve.
scanned=0
verified=0
commented=0
declare -a unresolved_files=()

# @description Emit this file's records, or exit 2 if `shfmt` cannot parse
# it. A tree that could not be built is a could-not-run, not a clean file:
# scoring it 0 would vouch for source nobody read.
# @arg $1 path to .sh file
# @exitcode 2 shfmt cannot parse the script
function records_of() {
  local -r file="$1"
  local tree
  # `--tojson` reads stdin only, so the file arrives by redirect and the
  # diagnostic below is what names it.
  if ! tree="$(shfmt --tojson <"${file}" 2>/dev/null)"; then
    log_err "cannot parse ${file}"
    exit 2
  fi
  jq -r "${JQ_PROGRAM}" <<<"${tree}"
}

# @description Scan a single shell file, adding its records to the scope
# tallies. Prints `file:line: <preview>` to stderr for each offender.
# Returns 0 on clean, 1 on any offender.
# @arg $1 path to .sh file
function scan_file() {
  local -r file="$1"
  local records
  # Captured with its status checked rather than read through a process
  # substitution, whose subshell keeps its own exit to itself: a parse
  # failure would leave the loop below reading nothing and the file would
  # score clean.
  if ! records="$(records_of "${file}")"; then
    exit 2
  fi

  scanned=$((scanned + 1))

  local offenders=0
  local kind line header preview
  local had_unresolved=0
  while IFS=$'\t' read -r kind line header preview; do
    [[ -n ${kind} ]] || continue
    case ${kind} in
    comment) commented=$((commented + 1)) ;;
    unresolved) had_unresolved=1 ;;
    call)
      if [[ ${header} == 'header' ]]; then
        verified=$((verified + 1))
        continue
      fi
      offenders=$((offenders + 1))
      if ((${#preview} > 120)); then
        preview="${preview:0:117}..."
      fi
      printf '%s:%s: missing X-GitHub-Api-Version header: %s\n' \
        "${file}" "${line}" "${preview}" >&2
      ;;
    esac
  done <<<"${records}"

  # Named once per file rather than once per word: the operator question
  # is which source this scan could not read, not how many times.
  ((had_unresolved == 0)) || unresolved_files+=("${file##*/}")

  ((offenders == 0))
}

failed=0
declare -a repo_scripts=()
glob_into repo_scripts 'repo shell scripts' "${SCRIPTS_DIR}/*.sh"
for sh in "${repo_scripts[@]}"; do
  scan_file "${sh}" || failed=$((failed + 1))
done

if ((failed > 0)); then
  printf '\n%d script(s) call the GitHub API without an explicit X-GitHub-Api-Version header.\n' \
    "${failed}" >&2
  printf 'Add `--header '\''X-GitHub-Api-Version: 2022-11-28'\''` (or matching API version) to each call.\n' >&2
  exit 1
fi

# A clean run reports the scope it covered, not just the verdict: a tree
# whose API calls all carry the header and a tree whose only API text sits
# in comments both pass, and the counts are what tell an operator which
# one the run actually saw. The unresolved field names the files this rule
# could not hold to anything, and the scan root names the tree it read —
# an overridable scan root that goes unstated makes a run over a fixture
# indistinguishable from a run over the repo.
unresolved_note="${#unresolved_files[@]} unresolved command word(s)"
if ((${#unresolved_files[@]} > 0)); then
  # Sorted under LC_ALL=C so the rendering is a property of the scan
  # rather than of the machine's collation. Read through word splitting
  # rather than a process substitution, whose producer status would be
  # lost to its subshell; a script basename holds no whitespace, so the
  # split is exact.
  declare -a unresolved_sorted=()
  for name in $(printf '%s\n' "${unresolved_files[@]}" | LC_ALL=C sort); do
    unresolved_sorted+=("${name}")
  done
  unresolved_note+=" [$(
    IFS=' '
    printf '%s' "${unresolved_sorted[*]}"
  )]"
fi
printf '%s: scanned %d script(s); %d API call site(s) carry an explicit header; %d comment mention(s) skipped; %s; scan root: %s\n' \
  'gh-api-version-header' "${scanned}" "${verified}" "${commented}" \
  "${unresolved_note}" "${SCRIPTS_DIR}"
exit 0
