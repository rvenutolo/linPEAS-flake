#!/usr/bin/env bash
# scripts/check-guard-exit-code.sh
#
# @description Lint: no scripts/*.sh may exit 1 out of a guard whose
# test is only an availability check. The exit codes separate what the
# operator has to do about a run: 2 means the check could not run (a
# required tool is absent, an input is missing, unreadable or
# malformed), 1 means it ran and found a violation, 0 means clean. An
# absent tool reported as 1 sends the operator hunting for drift in
# content the check never read, and a hook or job that reports both the
# same way makes a broken environment indistinguishable from a broken
# repo.
#
# A hit is a conditional whose test is PURELY an availability predicate
# and whose branch body exits 1:
#
#   if ! command -v X            if ! require_tool X
#   if [[ ! -f|-r|-e|-d|-s P ]]  [[ -f P ]] || { ... }
#
# Matching is branch-scoped rather than proximity-based: the branch body
# is walked from its opening keyword to the matching `fi` or closing
# brace, so an exit that merely sits a few lines below an availability
# test is not attributed to it. Many checks here read a marker or a
# field out of a file that exists and report its absence as the finding
# — those exits belong to the search that came back empty, not to the
# guard above them, and a line-window scan attributes exactly those to the wrong guard.
#
# A test that mixes an availability predicate with another predicate
# under `||` is not a hit: that branch is reachable without the input
# being absent, so absence there is half of a content verdict rather
# than a could-not-run.
#
# Escape hatch: `# exit-code-exempt: <rationale>` on the exit line, for
# a guard whose missing input genuinely IS the finding. The marker has
# to open the comment, so prose naming it exempts nothing, and the
# rationale has to be non-empty. A clean run prints the exemption count,
# so the exempt set is stated rather than open-ended.
#
# Honors SCRIPTS_DIR_OVERRIDE (default: scripts) for fixtures.
# Exit 0 clean, 1 on any hit, 2 on operational error.
set -Eeuo pipefail
IFS=$'\n\t'

readonly DIR="${SCRIPTS_DIR_OVERRIDE:-scripts}"
[[ -d ${DIR} ]] || {
  printf 'scripts dir not found: %s\n' "${DIR}" >&2
  exit 2
}

# The scanner walks one file and emits one TAB-separated record per
# finding: kind, exit line, guard line, detail. Keeping the structural
# walk in awk keeps the shell side to reporting, and every pattern below
# is written with character classes so this file never matches itself.
# shellcheck disable=SC2016 # awk program text: $0 and friends are awk fields, not shell expansions
readonly SCANNER='
function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

# A shell if opens a branch; the if of an awk program embedded in a
# script does not. The two are told apart by what follows the keyword:
# shell writes a test, a command or an arithmetic double paren, never a
# single paren.
function shell_ifs(t,   c) {
  c = gsub(/(^|[;&|{}( \t])if[ \t]*\(\(/, "", t)
  return c + gsub(/(^|[;&|{}( \t])if[ \t]+[^([:space:]]/, "", t)
}

function shell_fis(t) {
  return gsub(/(^|[;&|{}( \t])fi([ \t;&|)]|$)/, "", t)
}

# True when the predicate asserts the thing is NOT there — the shape an
# `if` guard tests before bailing out.
function avail_absent(t) {
  if (t ~ /![ \t]*-[fredsx][ \t]/) return 1
  if (t ~ /![ \t]*\[\[?[ \t]*-[fredsx][ \t]/) return 1
  if (t ~ /![ \t]*command[ \t]+-v[ \t]/) return 1
  if (t ~ /![ \t]*require_tool[ \t]/) return 1
  return 0
}

# True when the predicate asserts the thing IS there — the shape the
# `|| { ... }` form tests, whose group runs when it does not hold.
function avail_present(t) {
  if (t ~ /!/) return 0
  if (t ~ /\[\[?[ \t]*-[fredsx][ \t]/) return 1
  if (t ~ /(^|[;&|{}( \t])command[ \t]+-v[ \t]/) return 1
  if (t ~ /(^|[;&|{}( \t])require_tool[ \t]/) return 1
  return 0
}

# A test is purely availability when every route into the branch runs
# through an availability predicate: each `||` alternative must carry
# one, and one conjunct of an `&&` chain carrying it is enough, because
# the whole chain then requires it.
function pure(t, absent,   ndisj, D, i, nc, C, j, ok, all) {
  ndisj = split(t, D, /\|\|/)
  all = 1
  for (i = 1; i <= ndisj; i++) {
    nc = split(D[i], C, /&&/)
    ok = 0
    for (j = 1; j <= nc; j++) {
      if (absent == 1) {
        if (avail_absent(C[j])) ok = 1
      } else {
        if (avail_present(C[j])) ok = 1
      }
    }
    if (ok == 0) all = 0
  }
  return all
}

function report(kind, ln, detail) {
  printf "%s\t%d\t%d\t%s\n", kind, ln, guard_line, detail
}

function scan_exit(ln, text,   rest) {
  if (text !~ /(^|[;&|(){} \t])exit[ \t]+1([ \t]*[;#)]|[ \t]*$)/) return
  if (text ~ /#[ \t]*exit-code-exempt:/) {
    rest = text
    sub(/^.*#[ \t]*exit-code-exempt:[ \t]*/, "", rest)
    rest = trim(rest)
    if (rest == "") {
      report("norationale", ln, guard_text)
    } else {
      report("exempt", ln, rest)
    }
    return
  }
  report("hit", ln, guard_text)
}

# Enter the branch body of an accumulated `if` condition, but only when
# the condition is purely availability. A one-line `if ...; then ...; fi`
# is handled here too: its body is whatever follows `then`.
function start_body(   tmp, before, after) {
  tmp = cond
  if (match(tmp, /(^|[ \t;])then([ \t]|;|$)/)) {
    before = substr(tmp, 1, RSTART - 1)
    after = substr(tmp, RSTART + RLENGTH)
  } else {
    before = tmp
    after = ""
  }
  guard_text = trim(before)
  sub(/;[ \t]*$/, "", guard_text)
  guard_text = trim(guard_text)
  if (!pure(guard_text, 1)) {
    mode = "scan"
    return
  }
  mode = "ifbody"
  ifdepth = 1
  if (after != "") {
    scan_exit(guard_line, after)
    ifdepth = ifdepth - shell_fis(after)
    if (ifdepth <= 0) mode = "scan"
  }
}

# Brace depth for the `|| { ... }` form. Parameter expansions are erased
# first so the `}` closing a `${...}` is not read as closing the group.
function brace_delta(t,   n) {
  for (n = 0; n < 4; n++) gsub(/\$\{[^{}]*\}/, "", t)
  return gsub(/\{/, "", t) - gsub(/\}/, "", t)
}

BEGIN {
  mode = "scan"
  ifdepth = 0
  bdepth = 0
  condlines = 0
}

{
  line = $0
  # Whole-line comments are blanked, keeping the line count intact, so a
  # header that names a banned shape is not read as that shape.
  if (line ~ /^[ \t]*#/) line = ""

  if (mode == "cond") {
    cond = cond " " line
    condlines = condlines + 1
    if (line ~ /(^|[ \t;])then([ \t]|;|$)/) {
      start_body()
    } else if (condlines > 6) {
      mode = "scan"
    }
    next
  }

  if (mode == "ifbody") {
    if (ifdepth == 1 && line ~ /^[ \t]*(else|elif)([ \t]|$)/) {
      mode = "scan"
      next
    }
    scan_exit(FNR, line)
    ifdepth = ifdepth + shell_ifs(line) - shell_fis(line)
    if (ifdepth <= 0) mode = "scan"
    next
  }

  if (mode == "brace") {
    scan_exit(FNR, line)
    bdepth = bdepth + brace_delta(line)
    if (bdepth <= 0) mode = "scan"
    next
  }

  if (line ~ /^[ \t]*if[ \t]/ && avail_absent(line)) {
    cond = line
    sub(/^[ \t]*if[ \t]+/, "", cond)
    guard_line = FNR
    condlines = 1
    if (line ~ /(^|[ \t;])then([ \t]|;|$)/) {
      start_body()
    } else {
      mode = "cond"
    }
    next
  }

  if (line ~ /\|\|[ \t]*\{[ \t]*$/) {
    cond = line
    sub(/\|\|[ \t]*\{[ \t]*$/, "", cond)
    if (pure(cond, 0)) {
      guard_line = FNR
      guard_text = trim(cond)
      mode = "brace"
      bdepth = 1
    }
    next
  }
}
'

failed=0
exempted=0
scanned=0
shopt -s nullglob
for f in "${DIR}"/*.sh; do
  scanned=$((scanned + 1))
  # Captured rather than piped so a scanner failure aborts the run
  # instead of handing this loop an empty stream to score as clean.
  findings="$(awk -- "${SCANNER}" <"${f}")"
  [[ -z ${findings} ]] && continue
  while IFS=$'\t' read -r kind exit_line guard_line detail; do
    [[ -z ${kind} ]] && continue
    case "${kind}" in
    hit)
      printf '%s:%s: exits 1 inside a guard whose test at line %s is only an availability check (%s); an absent tool or input is a could-not-run, so exit 2\n' \
        "${f}" "${exit_line}" "${guard_line}" "${detail}" >&2
      failed=$((failed + 1))
      ;;
    norationale)
      printf '%s:%s: exit-code-exempt marker carries no rationale; the guard at line %s (%s) stays a hit until the marker says why the missing input is the finding\n' \
        "${f}" "${exit_line}" "${guard_line}" "${detail}" >&2
      failed=$((failed + 1))
      ;;
    exempt)
      exempted=$((exempted + 1))
      ;;
    esac
  done <<<"${findings}"
done
shopt -u nullglob

if ((failed > 0)); then
  printf '%d could-not-run guard(s) on the wrong side of the exit-code convention\n' "${failed}" >&2
  exit 1
fi

printf 'guard-exit-code: %d script(s) scanned, %d exemption(s)\n' "${scanned}" "${exempted}"
exit 0
