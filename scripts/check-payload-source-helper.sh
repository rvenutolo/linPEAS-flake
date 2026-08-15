#!/usr/bin/env bash
# scripts/check-payload-source-helper.sh
#
# @description Lint: no shell file names a payload's source by hand.
# `payload_source_into` (scripts/lib/payload.sh) fills a caller variable
# with the override variable's name when a fixture supplies the payload
# and with the API route or config filename otherwise, so an assignment
# that sets a variable to a bare `*_OVERRIDE` variable name is a copy of
# a rule the library already owns. Ten such copies existed across nine
# scripts, in two spellings that had already drifted apart from each
# other, which is what a rule with no enforcer costs: the shape gate they
# all feed reads the source name verbatim into every diagnostic, so a
# copy that resolves the override differently from the reader beside it
# names a source the run never used.
#
# --- Why an AST, not a grep ----------------------------------------------
#
# The banned shape is a text-shaped shortcut, and a gate whose purpose is
# rejecting one must not accept one itself. A textual matcher keyed on
# `=('|")?[A-Z_]*_OVERRIDE` reads the override name out of prose, out of
# a heredoc, and out of this file's own diagnostics; it also misses the
# same assignment written unquoted. `shfmt --to-json` answers the only
# question that matters — is this a variable assignment whose entire
# value is one literal word spelling an override variable's name — and
# answers it identically for all three spellings the parser distinguishes:
# a single-quoted word, a bare literal word, and a double-quoted word
# wrapping one literal part.
#
# Both `CallExpr` assignments (`src='X_OVERRIDE'`) and `DeclClause`
# arguments (`local src='X_OVERRIDE'`, `readonly`, `declare`, `export`)
# are read. The parser files those under different node types, and the
# two scripts that named a source inside a function body would have had
# the declared form available to them, so a scan of bare assignments
# alone leaves the shape most likely to be written next unreachable.
#
# --- Exemption -----------------------------------------------------------
#
# An assignment that spells an override variable's name for some reason
# other than naming a payload source — an operator message telling a
# reader which variable to set, say — is excused by an inline
# `# payload-source-exempt: <rationale>` marker anywhere in the file,
# matching this repo's existing `payload-subject-exempt` /
# `enumerate-exempt` / `glob-exempt` convention: the rationale lives
# beside the code it excuses rather than in a hand-maintained doc table
# that drifts silently. A marker with an empty rationale excuses nothing
# — an exemption nobody has to justify is a way to switch the rule off in
# place. A marker on a file holding no assignment the rule matches is
# itself reported, and that report is produced before any violation is,
# so a stale marker surfaces on a tree where the rule is otherwise
# obeyed everywhere.
#
# --- Breadth -------------------------------------------------------------
#
# The scan set is `<scripts>/*.sh`, `<scripts>/lib/*.sh` and
# `<tests>/*.sh`. The library arm is not optional: the helper itself
# lives there, its neighbors are the files most likely to copy it, and
# the older shell-hygiene lints in this repo stop at the top level. The
# clean verdict reports files scanned and assignments examined rather
# than a bare "ok", because a detector that stopped reaching assignments
# and a tree with nothing to report emit the same exit code otherwise.
#
# Measured, not assumed: this file's own prose does not self-match. The
# finished lint run against a scan root holding only this script reports
# zero violations across the 30 assignments it examines there — every
# mention of the banned shape here is a comment or a format string,
# neither of which the parser files as an assignment — so this file needs
# no exemption marker of its own.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts), TESTS_DIR_OVERRIDE
# (default: tests), and LINT_ALLOW_EMPTY_SCAN for a scan root that
# deliberately holds no assignment at all.
# Exit 0 clean, 1 on a hand-named source or a stale exemption marker,
# 2 when the scan set cannot be enumerated, holds no assignment, a
# required tool is missing, or a file cannot be parsed as shell.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"

# A missing shfmt or jq must be diagnosed as itself rather than as the
# per-file could-not-parse message below, which is reserved for a file
# that genuinely fails to parse once both tools are known present.
require_tool shfmt
require_tool jq

readonly SCRIPTS_DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
readonly TESTS_DIR="${TESTS_DIR_OVERRIDE:-tests}"

readonly MARKER_RE='^[[:space:]]*#[[:space:]]*payload-source-exempt:[[:space:]]*([^[:space:]].*)?$'

# jq program over one file's syntax tree. It emits the count of named
# assignments in the file on its first line, then one tab-separated
# `line<TAB>variable<TAB>literal` row per assignment whose whole value is
# a literal spelling an override variable's name.
#
# The count shares this program rather than coming from a second, simpler
# one so that it cannot be produced by a run this program did not
# complete: the count is the tally every clean scenario asserts, and a
# tally a failed scan can still emit proves nothing about the scan.
#
# `select(.Name != null)` drops a declaration's flag words — the `-r` of
# `local -r x=y` is filed as an argument with no name — whose position
# the row below could not report.
#
# The `// ""` coalesce is load-bearing rather than defensive padding.
# The parser omits a node's value field when the value is empty, so an
# empty single-quoted assignment (`live=''`) yields a quoted word with no
# value at all, and `test()` against null aborts jq with exit 5. That
# abort took out every remaining file in the scan while this detector was
# being written, and the sites it swallowed looked exactly like sites
# that were not there.
# shellcheck disable=SC2016 # jq program literal; $-prefixed names are jq variables, not shell
readonly AST_PROG='
[.. | objects
  | select(.Type == "CallExpr" or .Type == "DeclClause")
  | ((.Assigns // []) + (.Args // []))[]
  | select(.Name != null)] as $assigns
| ($assigns | length) as $count
| [$assigns[]
  | select((.Value.Parts | length) == 1)
  | . as $a | (.Value.Parts[0]) as $p
  | ((if $p.Type == "SglQuoted" then $p.Value
      elif $p.Type == "Lit" then $p.Value
      elif ($p.Type == "DblQuoted" and (($p.Parts | length) == 1)
        and ($p.Parts[0].Type == "Lit")) then $p.Parts[0].Value
      else "" end) // "") as $lit
  | select($lit | test("^[A-Z][A-Z0-9_]*_OVERRIDE$"))
  | "\($a.Name.Pos.Line)\t\($a.Name.Value)\t\($lit)"] as $rows
| (["\($count)"] + $rows) | .[]
'

# @description Echo the exemption marker's rationale for $1, or nothing
# (and fail) if the file carries no valid marker. A marker whose
# rationale is empty does not count — the same "empty exemption is drift,
# not an exemption" rule this repo's sibling markers already enforce.
# @arg $1 file to read
function exempt_rationale() {
  local -r f="$1"
  local line
  while IFS= read -r line; do
    if [[ ${line} =~ ${MARKER_RE} ]]; then
      [[ -n ${BASH_REMATCH[1]:-} ]] || continue
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <"${f}"
  return 1
}

declare -a scan_set=()
glob_into scan_set "shell files under ${SCRIPTS_DIR}, ${SCRIPTS_DIR}/lib and ${TESTS_DIR}" \
  "${SCRIPTS_DIR}/*.sh" "${SCRIPTS_DIR}/lib/*.sh" "${TESTS_DIR}/*.sh"

files_scanned=0
assignments_examined=0
exemptions_applied=0
declare -a stale_findings=()
declare -a violation_findings=()

# Each file is parsed once and its findings are sorted into the two
# report buckets below, rather than being walked twice. The stale-marker
# rule needs the same answer the violation rule does — whether this file
# holds an assignment the rule matches — so a second pass would re-run
# both tools over the whole tree to re-derive what the first already
# knew.
for file in "${scan_set[@]}"; do
  # shfmt and jq are each run on their own line with their own status
  # checked. A tool that fell over on one file must be reported as a
  # could-not-run for that file: a swallowed status here yields an empty
  # result set, which reads exactly like a file with nothing to report.
  ast_json=''
  if ! ast_json="$(shfmt --to-json <"${file}" 2>/dev/null)"; then
    printf '%s: shfmt could not parse this file as shell for AST inspection\n' \
      "${file}" >&2
    exit 2
  fi

  report=''
  if ! report="$(jq --raw-output "${AST_PROG}" <<<"${ast_json}")"; then
    printf '%s: jq failed walking the parsed syntax tree\n' "${file}" >&2
    exit 2
  fi

  declare -a rows=()
  mapfile -t rows <<<"${report}"
  files_scanned=$((files_scanned + 1))
  assignments_examined=$((assignments_examined + rows[0]))

  if rationale="$(exempt_rationale "${file}")"; then
    if ((${#rows[@]} > 1)); then
      exemptions_applied=$((exemptions_applied + 1))
    else
      stale_findings+=("$(printf '%s: carries a payload-source-exempt marker but holds no assignment the rule matches (marker rationale: %s)' \
        "${file}" "${rationale}")")
    fi
    continue
  fi

  for ((i = 1; i < ${#rows[@]}; i++)); do
    IFS=$'\t' read -r hit_line hit_var hit_lit <<<"${rows[i]}"
    violation_findings+=("$(printf '%s:%s: %s=%s hand-names a payload source — fill it with payload_source_into (%s/lib/payload.sh), or mark the file with a "# payload-source-exempt: <rationale>" comment' \
      "${file}" "${hit_line}" "${hit_var}" "'${hit_lit}'" "${SCRIPTS_DIR}")")
  done
done

failed=0
for finding in "${stale_findings[@]}" "${violation_findings[@]}"; do
  printf '%s\n' "${finding}" >&2
  failed=$((failed + 1))
done

# A finding is a real result and takes priority over the empty-scan guard
# below: a marker excusing nothing on a file holding no assignment at all
# is still something this run learned, not a scan that came back with
# nothing to say.
if ((failed > 0)); then
  printf '%d payload-source-helper violation(s)\n' "${failed}" >&2
  exit 1
fi

if ((assignments_examined == 0)) && [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  printf '%s: examined 0 assignment(s) across %d file(s) under %s, %s/lib and %s — set LINT_ALLOW_EMPTY_SCAN=1 if this root deliberately holds none\n' \
    "${0##*/}" "${files_scanned}" "${SCRIPTS_DIR}" "${SCRIPTS_DIR}" "${TESTS_DIR}" >&2
  exit 2
fi

printf '%s: ok — %d file(s) scanned, %d assignment(s) examined, %d violation(s), %d exemption(s) applied\n' \
  "${0##*/}" "${files_scanned}" "${assignments_examined}" "${failed}" "${exemptions_applied}"
exit 0
