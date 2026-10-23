#!/usr/bin/env bash
# scripts/check-runner-doc-diff.sh
#
# @description Content floor for a bot push of a runner-label doc: exit 0
# only when a new copy of docs/architecture/ci.md or docs/install/nix.md
# differs from the old one in nothing but the runner cells of its table
# and the padding inside that table.

# The doc is regenerated in a job that runs code from the pull request
# branch, and the job that pushes it holds a write credential, so the
# push must not trust the generator. This script is that check, and it
# shares no code with scripts/refresh-runner-labels.sh: a fault in the
# generator, or a generator rewritten on the branch, cannot reach the
# rule that polices it.
#
# The rule:
#   - both files have the same line count and the same final newline;
#   - the table is the one whose header row's trimmed cells are
#     `Job | Runner | What it tests` (ci.md) or
#     `System | Flake builds | CI tested` (nix.md), outside fenced code,
#     appearing exactly once in each file at the same line; it runs from
#     the header row through the last consecutive line starting with `|`;
#   - every line outside the table is byte-identical;
#   - inside the table every row has as many cells as the header, every
#     separator cell is a run of dashes on both sides, and every cell
#     compares equal once its padding is trimmed, except the runner
#     column (Runner in ci.md, CI tested in nix.md) of a body row;
#   - a runner cell that changed is one backticked label (ci.md) or
#     `yes (` + a backticked label + `)` (nix.md), on both sides, where a
#     label is a letter or digit followed by letters, digits, `.`, `_`
#     and `-`, the runs-on label charset. The docs site renders pages
#     through mkdocs-macros before Markdown, so a cell admitting `{`,
#     `%` or a space could carry template code into the Pages build.
# Trimmed comparison is what lets the generator re-pad the whole table
# when a wider label lands. A table line holding a control-A byte is
# refused: the cell split stands that byte in for an escaped pipe, so a
# row holding one could compare equal to a different row.
#
# Refusals name the first offending line and never echo the new file's
# text, which comes from an untrusted job.
#
# Usage:
#   scripts/check-runner-doc-diff.sh <doc-path> <old-file> <new-file>
#
# <doc-path> is docs/architecture/ci.md or docs/install/nix.md and picks
# the header row and runner column; the two files are read, not the
# checkout's copy of the doc.
#
# Exit codes:
#   0  only runner cells (and table padding) differ
#   1  refused: stderr names the first offending line and the reason
#   2  could not check: wrong argument count, an unknown doc path, a file
#      that is not a readable regular file, a missing tool, or an awk
#      that fails or prints no verdict

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
install_err_trap

if [[ $# -ne 3 ]]; then
  log_err 'usage: check-runner-doc-diff.sh <doc-path> <old-file> <new-file>'
  exit 2
fi
readonly DOC_PATH="$1"
readonly OLD_FILE="$2"
readonly NEW_FILE="$3"

# The comparer. It is POSIX awk, because the job that runs it has only
# the runner image's awk, which on ubuntu-latest is mawk. Both files are
# read with getline from ENVIRON, not as operands, so no path is ever
# parsed as an awk assignment, and the program is BEGIN-only. It runs
# under LC_ALL=C: every comparison is byte for byte and nothing measures
# a width. awk cannot see whether a file's last line ends in a newline,
# so the caller passes that in as `old_nl` / `new_nl` (1 or 0). Output is
# one tab-tagged line on stdout, `ok`, `refuse` or `cannot`; the caller
# accepts a verdict only when the tag matches the exit status.
# shellcheck disable=SC2016 # awk program text; its $ fields are awk's
readonly FLOOR_AWK='
function refuse(line, msg) {
  print "refuse\t" docname ":" line ": " msg
  exit 1
}
function cannot(msg) {
  print "cannot\t" msg
  exit 2
}
function trim(s) {
  gsub(/^[ \t]+|[ \t]+$/, "", s)
  return s
}
# Split one table line into trimmed cells; an escaped pipe stays in its
# cell. Returns the cell count, or -1 for a line not bounded by pipes.
function cells(line, out,   n, i, parts) {
  delete out
  gsub(/\\\|/, "\001", line)
  sub(/[ \t]+$/, "", line)
  if (line !~ /^\|.*\|$/) return -1
  line = substr(line, 2, length(line) - 2)
  n = split(line, parts, "|")
  for (i = 1; i <= n; i++) {
    gsub(/\001/, "\\|", parts[i])
    out[i] = trim(parts[i])
  }
  return n
}
function header_text(   i, s) {
  s = "|"
  for (i = 1; i <= hn; i++) s = s " " want[i] " |"
  return s
}
function slurp(path, lines,   n, rc, line) {
  n = 0
  while ((rc = (getline line < path)) > 0) lines[++n] = line
  if (rc < 0) cannot("cannot read " path)
  close(path)
  return n
}
# The line of the one header row outside fenced code.
function locate(lines, n, side,   i, k, c, fence, found, at, same) {
  fence = 0
  found = 0
  for (i = 1; i <= n; i++) {
    # Up to three spaces of indent, spelled out: not every awk reads
    # interval expressions.
    if (lines[i] ~ /^ ? ? ?(```|~~~)/) { fence = !fence; continue }
    if (fence || lines[i] !~ /^\|/) continue
    if (cells(lines[i], c) != hn) continue
    same = 1
    for (k = 1; k <= hn; k++) if (c[k] != want[k]) same = 0
    if (!same) continue
    if (found) refuse(i, side " file: the header row appears again (first at line " at ")")
    found = 1
    at = i
  }
  if (!found) {
    print "refuse\t" docname ": " side " file: no table with the header row " header_text()
    exit 1
  }
  return at
}
function shaped(cell) {
  return mode == "ci" ? cell ~ /^`[A-Za-z0-9][A-Za-z0-9._-]*`$/ : cell ~ /^yes \(`[A-Za-z0-9][A-Za-z0-9._-]*`\)$/
}
BEGIN {
  hn = split(header, want, "|")
  col = mode == "ci" ? 2 : 3
  shape = mode == "ci" ? "one backticked label" : "yes (<backticked label>)"

  if (old_nl !~ /^[01]$/ || new_nl !~ /^[01]$/) cannot("bad final-newline flags")
  n = slurp(ENVIRON["FLOOR_OLD"], o)
  m = slurp(ENVIRON["FLOOR_NEW"], w)
  if (n != m) {
    for (i = 1; i <= n && i <= m && o[i] == w[i]; i++) ;
    refuse(i, "line count changed (old " n " lines, new " m ")")
  }
  if (old_nl != new_nl) refuse(n, "the final newline was added or removed")

  start = locate(o, n, "old")
  for (stop = start; stop <= n && o[stop] ~ /^\|/; stop++) ;
  for (i = 1; i <= n; i++) {
    if ((i < start || i >= stop) && o[i] != w[i]) refuse(i, "line outside the table changed")
  }
  if (stop - start < 2) refuse(start, "the table has no separator row")

  changed_cells = 0
  changed_lines = 0
  for (i = start; i < stop; i++) {
    r = i - start + 1
    if (index(o[i], "\001") || index(w[i], "\001")) refuse(i, "the table line holds a control-A byte")
    no = cells(o[i], co)
    nw = cells(w[i], cw)
    if (no != hn) refuse(i, "the old row has " (no < 0 ? 0 : no) " cells; the header has " hn)
    if (nw != hn) refuse(i, "the new row has " (nw < 0 ? 0 : nw) " cells; the header has " hn)
    if (o[i] != w[i]) changed_lines++
    for (k = 1; k <= hn; k++) {
      if (r == 2) {
        if (co[k] !~ /^-+$/ || cw[k] !~ /^-+$/) refuse(i, "separator cell " k " is not a run of dashes")
        continue
      }
      if (co[k] == cw[k]) continue
      if (r == 1 || k != col) refuse(i, "cell " k " (" want[k] ") changed")
      if (!shaped(co[k])) refuse(i, "the old runner cell is not " shape)
      if (!shaped(cw[k])) refuse(i, "the new runner cell is not " shape)
      changed_cells++
    }
  }
  # Implied by the checks above; kept so the two files are held to the
  # same table even if one of those checks is ever loosened.
  if (locate(w, m, "new") != start) refuse(start, "the new file has its table header on another line")

  print "ok\t" docname ": " changed_cells " runner cell(s) changed, " changed_lines " table line(s) differ; nothing else does"
  exit 0
}
'

function main() {
  local header mode
  case "${DOC_PATH}" in
  docs/architecture/ci.md)
    mode='ci'
    header='Job|Runner|What it tests'
    ;;
  docs/install/nix.md)
    mode='nix'
    header='System|Flake builds|CI tested'
    ;;
  *)
    log_err "unknown doc path: ${DOC_PATH} (want docs/architecture/ci.md or docs/install/nix.md)"
    exit 2
    ;;
  esac
  readonly header mode

  local f
  for f in "${OLD_FILE}" "${NEW_FILE}"; do
    if [[ ! -f ${f} || ! -r ${f} ]]; then
      log_err "${f}: not a readable file"
      exit 2
    fi
  done

  require_tool awk
  require_tool tail
  require_tool wc

  local out
  out="$(make_temp)"
  # shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
  trap "rm --force -- '${out}'" EXIT

  # 1 when the file's last byte is a newline, 0 otherwise (an empty file
  # included).
  local old_nl new_nl
  old_nl="$(tail --bytes=1 -- "${OLD_FILE}" | wc --lines)"
  new_nl="$(tail --bytes=1 -- "${NEW_FILE}" | wc --lines)"

  local rc=0
  FLOOR_OLD="${OLD_FILE}" FLOOR_NEW="${NEW_FILE}" LC_ALL=C \
    awk -v mode="${mode}" -v header="${header}" -v docname="${DOC_PATH}" \
    -v old_nl="${old_nl}" -v new_nl="${new_nl}" "${FLOOR_AWK}" >"${out}" || rc=$?

  # Only a verdict whose tag matches the exit status counts; an awk that
  # died, or printed anything else, reads as could-not-check.
  local msg tag text
  msg="$(<"${out}")"
  tag="${msg%%$'\t'*}"
  text="${msg#*$'\t'}"
  if [[ ${msg} == *$'\n'* ]]; then
    tag='multi-line'
  fi
  case "${rc}:${tag}" in
  0:ok)
    log_info "${text}"
    ;;
  1:refuse)
    log_err "${text}"
    exit 1
    ;;
  2:cannot)
    log_err "${text}"
    exit 2
    ;;
  *)
    log_err "could not compare the two copies of ${DOC_PATH} (awk exit ${rc})"
    exit 2
    ;;
  esac
}

main "$@"
