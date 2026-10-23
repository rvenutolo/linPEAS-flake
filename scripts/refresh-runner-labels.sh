#!/usr/bin/env bash
# scripts/refresh-runner-labels.sh
#
# @description Rewrite the runner labels in the functional-gates table of
# docs/architecture/ci.md and the platform-support table of
# docs/install/nix.md from the runs-on: of the jobs in
# .github/workflows/ci.yml.
# @generates-block docs/architecture/ci.md
# @generates-block docs/install/nix.md
# @option --check exit 1 if either doc would change; exit 2 if an input
# file is missing, if a table's header row is missing or appears more than
# once, if a row is malformed or names a job ci.yml lacks or a system no
# job feeds, if a table job's runs-on is not one plain runner label, if
# the jobs feeding one system disagree on their runner, if ci.yml holds a
# job key the job list cannot carry (see scripts/lib/job-keys.sh), or if
# a tool fails to read the inputs

# The ci.md table is the one whose header row is
# `| Job | Runner | What it tests |`; each row's Runner cell becomes the
# backticked runs-on: label of the job its first cell names. The nix.md
# table is the one whose header row is `| System | Flake builds | CI tested |`;
# its `aarch64-linux` row takes the runner shared by the ci.md table's jobs
# whose names end `-arm64`, its `x86_64-linux` row the runner shared by
# the rest. The tables carry no BEGIN/END markers, so the text around them
# stays in reach of every prose lint; each is found by its header row,
# compared cell by cell with the padding trimmed. Only those cells change;
# every row of a table is then re-padded as mdformat lays a table out
# (each column as wide as its widest cell and at least three, measured in
# code points), so treefmt leaves the result as it is. Code points are
# mdformat's display width for every character but East Asian wide and
# zero-width ones, which the tables do not hold.
#
# Usage:
#   scripts/refresh-runner-labels.sh           # rewrite the docs in place
#   scripts/refresh-runner-labels.sh --check   # exit 1 if a doc would change;
#                                              # exit 2 on any input error
#                                              # listed under --check above
#
# Env overrides (for tests):
#   CI_WORKFLOW_OVERRIDE  path to ci.yml
#   CI_DOC_OVERRIDE       path to ci.md
#   NIX_DOC_OVERRIDE      path to nix.md

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"
# shellcheck source=scripts/lib/job-keys.sh
source "${_lib_dir}/lib/job-keys.sh"
install_err_trap

# The table rewriter, shared by both docs. `mode` is `ci` or `nix`;
# `inputs` holds `<job>\t<status>\t<value>` lines (ci) or
# `<system>\t<label>` lines (nix); in ci mode the shared runner of each
# system is written to `systems`. A refusal is written to `errs` and ends
# the run with exit 2. It runs under a UTF-8 locale so length() counts
# code points, as mdformat measures a cell.
# shellcheck disable=SC2016 # awk program text; its $ fields are awk's
readonly TABLE_AWK='
function fail(msg) {
  print msg > errs
  close(errs)
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
function header_text(h,   i, s) {
  s = "|"
  for (i = 1; i <= hn; i++) s = s " " h[i] " |"
  return s
}
BEGIN {
  hn = split(header, want, "|")
  if (mode == "ci") {
    while ((getline rec < inputs) > 0) {
      split(rec, f, "\t")
      status[f[1]] = f[2]
      value[f[1]] = f[3]
    }
  } else {
    while ((getline rec < inputs) > 0) {
      split(rec, f, "\t")
      label[f[1]] = f[2]
    }
  }
  close(inputs)
}
{ doc[NR] = $0 }
END {
  fence = 0
  found = 0
  for (i = 1; i <= NR; i++) {
    if (doc[i] ~ /^ {0,3}(```|~~~)/) { fence = !fence; continue }
    if (fence || doc[i] !~ /^\|/) continue
    n = cells(doc[i], c)
    if (n != hn) continue
    same = 1
    for (k = 1; k <= hn; k++) if (c[k] != want[k]) same = 0
    if (same) { found++; start = i }
  }
  if (found == 0) fail(docname ": no table with the header row " header_text(want))
  if (found > 1) fail(docname ": the header row " header_text(want) " appears " found " times; want one")

  rows = 0
  for (i = start; i <= NR && doc[i] ~ /^\|/; i++) {
    rows++
    n = cells(doc[i], c)
    if (n != hn) fail(docname ":" i ": row has " (n < 0 ? 0 : n) " cells; the header has " hn)
    for (k = 1; k <= hn; k++) t[rows, k] = c[k]
  }
  stop = i
  if (rows < 2) fail(docname ":" start ": the table has no separator row")
  for (k = 1; k <= hn; k++) {
    if (t[2, k] !~ /^-+$/) fail(docname ":" (start + 1) ": separator cell " k " is not a run of dashes (column alignment is not supported)")
  }

  for (r = 3; r <= rows; r++) {
    line = start + r - 1
    if (mode == "ci") {
      if (t[r, 1] !~ /^`[^`]+`$/) fail(docname ":" line ": the Job cell is not one backticked job name: " t[r, 1])
      job = substr(t[r, 1], 2, length(t[r, 1]) - 2)
      if (!(job in status)) fail(docname ":" line ": the table names job " job ", which " workflow " does not define")
      if (status[job] != "label") {
        got = status[job] == "string" ? "a string that is not a runner label" : (status[job] == "kind" && value[job] != "" ? value[job] : "no runs-on")
        fail(workflow ": job " job " has a runs-on that is not one plain runner label (got " got ")")
      }
      t[r, 2] = "`" value[job] "`"
      sys = job ~ /-arm64$/ ? "aarch64-linux" : "x86_64-linux"
      if (!(sys in shared)) { shared[sys] = value[job]; first_job[sys] = job }
      else if (shared[sys] != value[job]) {
        fail(docname ": the jobs feeding " sys " run on different runners: " first_job[sys] " on " shared[sys] ", " job " on " value[job])
      }
    } else {
      if (t[r, 1] == "`x86_64-linux`") sys = "x86_64-linux"
      else if (t[r, 1] == "`aarch64-linux`") sys = "aarch64-linux"
      else fail(docname ":" line ": row for system " t[r, 1] "; only x86_64-linux and aarch64-linux are fed by ci jobs")
      if (sys in seen) fail(docname ":" line ": a second row for " sys)
      seen[sys] = 1
      if (!(sys in label)) fail(docname ":" line ": no job in the functional-gates table feeds " sys)
      t[r, 3] = "yes (`" label[sys] "`)"
    }
  }
  if (mode == "ci") {
    for (sys in shared) printf "%s\t%s\n", sys, shared[sys] > systems
    close(systems)
  } else {
    if (!("x86_64-linux" in seen)) fail(docname ": the platform-support table has no row for x86_64-linux")
    if (!("aarch64-linux" in seen)) fail(docname ": the platform-support table has no row for aarch64-linux")
  }

  for (k = 1; k <= hn; k++) {
    w[k] = 3
    for (r = 1; r <= rows; r++) if (r != 2 && length(t[r, k]) > w[k]) w[k] = length(t[r, k])
  }
  for (i = 1; i < start; i++) print doc[i]
  for (r = 1; r <= rows; r++) {
    out = "|"
    for (k = 1; k <= hn; k++) {
      cell = t[r, k]
      if (r == 2) { cell = ""; while (length(cell) < w[k]) cell = cell "-" }
      out = out " " sprintf("%s%*s", cell, w[k] - length(cell), "") " |"
    }
    print out
  }
  for (i = stop; i <= NR; i++) print doc[i]
}
'

function main() {
  local check_only='false'
  if [[ ${1:-} == '--check' ]]; then
    check_only='true'
  elif [[ -n ${1:-} ]]; then
    log_err "unknown arg: ${1}"
    exit 2
  fi
  readonly check_only

  # Force byte-deterministic collation for every downstream tool; the
  # table rewriter alone runs under C.UTF-8 to measure cells.
  export LC_ALL=C

  require_tool git
  require_tool yq
  require_tool awk
  require_tool cmp

  local repo_root workflow ci_doc nix_doc
  repo_root="$(repo_toplevel)"
  workflow="${CI_WORKFLOW_OVERRIDE:-${repo_root}/.github/workflows/ci.yml}"
  ci_doc="${CI_DOC_OVERRIDE:-${repo_root}/docs/architecture/ci.md}"
  nix_doc="${NIX_DOC_OVERRIDE:-${repo_root}/docs/install/nix.md}"
  readonly repo_root workflow ci_doc nix_doc

  # An absent input is a could-not-run condition, not drift.
  local f
  for f in "${workflow}" "${ci_doc}" "${nix_doc}"; do
    if [[ ! -f ${f} ]]; then
      log_err "${f} not found"
      exit 2
    fi
  done

  local tmp
  tmp="$(make_temp --directory)"
  # shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
  trap "rm --recursive --force -- '${tmp}'" EXIT

  # A job key the job list cannot carry would read as other jobs or as
  # none, so a row could be matched against a job nothing read.
  local odd_key
  if ! odd_key="$(first_unlistable_job_key "${workflow}")"; then
    log_err "could not read the runners from ${workflow}"
    exit 2
  fi
  if [[ -n ${odd_key} ]]; then
    log_err "$(odd_job_key_message "${workflow}" "${odd_key}")"
    exit 2
  fi

  # One line per job: `<job>\tlabel\t<runs-on>` for a runs-on that is one
  # plain runner label, `<job>\tstring\t` for any other string (an
  # expression, or text a table cell cannot hold), `<job>\tkind\t<tag>`
  # for a runs-on that is no string or is absent. A merge key brings in
  # its jobs and the keys inside them, read first mapping wins.
  # shellcheck disable=SC2016 # yq program text; its $ names are yq variables
  local -r runners_q="[(${JOBS_NODE} // {}) | ${RESOLVE_JOB_ALIASES}"' | select(kind == "map") | to_entries[] | .key + "\t" + ((.value | select(kind == "map") | .["runs-on"]) as $r | if ($r | tag) == "!!str" then (if ($r | test("^[A-Za-z0-9._-]+$")) then "label\t" + $r else "string\t" end) else "kind\t" + ($r | tag) end)] | .[]'
  if ! yq eval "${YQ_MERGE_SPEC[@]}" "${runners_q}" "${workflow}" >"${tmp}/runners"; then
    log_err "could not read the runners from ${workflow}"
    exit 2
  fi

  local doc rc path header inputs
  for doc in ci nix; do
    rc=0
    path="${ci_doc}" header='Job|Runner|What it tests' inputs="${tmp}/runners"
    if [[ ${doc} == nix ]]; then
      path="${nix_doc}" header='System|Flake builds|CI tested' inputs="${tmp}/systems"
    fi
    : >"${tmp}/errs"
    LC_ALL=C.UTF-8 awk -v mode="${doc}" -v header="${header}" -v inputs="${inputs}" \
      -v systems="${tmp}/systems" -v errs="${tmp}/errs" -v docname="${path}" \
      -v workflow="${workflow}" "${TABLE_AWK}" "$(awk_path "${path}")" >"${tmp}/${doc}.md" || rc=$?
    if [[ ${rc} -ne 0 ]]; then
      if [[ -s ${tmp}/errs ]]; then
        while IFS= read -r f; do log_err "${f}"; done <"${tmp}/errs"
      else
        log_err "could not rewrite the runner labels in ${path} (awk exit ${rc})"
      fi
      exit 2
    fi
  done

  local -a stale=()
  cmp --silent -- "${ci_doc}" "${tmp}/ci.md" || stale+=("${ci_doc}")
  cmp --silent -- "${nix_doc}" "${tmp}/nix.md" || stale+=("${nix_doc}")

  if [[ ${check_only} == 'true' ]]; then
    if [[ ${#stale[@]} -gt 0 ]]; then
      for f in "${stale[@]}"; do
        log_err "runner labels in ${f} are stale. Run scripts/refresh-runner-labels.sh and commit."
      done
      exit 1
    fi
    log_info "runner labels in ${ci_doc} and ${nix_doc} are up to date"
    return 0
  fi

  # Written over the doc rather than moved onto it, so the doc keeps its
  # own mode instead of the temp file's.
  cp -- "${tmp}/ci.md" "${ci_doc}"
  cp -- "${tmp}/nix.md" "${nix_doc}"
  log_info "refreshed runner labels in ${ci_doc} and ${nix_doc}"
}

main "$@"
