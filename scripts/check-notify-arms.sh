#!/usr/bin/env bash
# scripts/check-notify-arms.sh
#
# @description Lint: every stated arm list of a scanner notify job must
# equal the arms its workflow actually files on. An arm is a result of the
# watched job that makes the notify job open or update its deduped issue.
# The arms are derived from the workflow, never written down here: the
# notify job's `if:` gate is evaluated over every combination of the
# watched job's result, its `has-finding` output and the triggering event,
# and the `result:` it hands the notify-workflow-result composite decides
# which of those combinations file an issue.
#
# A prose site declares the arm list it restates with a marker comment in
# the same paragraph:
#
#   A finding, a failure with no finding, or a cancelled job is paged
#   <!-- notify-arms: codeql.yml/notify-infra = failure cancelled non-pr -->
#   under `codeql-infra`.
#
# The tokens after `=` are a set, in any order:
#
#   finding    the watched job failed and its `has-finding` output is 'true'
#   failure    the watched job failed with no such finding (or declares no
#              `has-finding` output at all)
#   cancelled  the watched job was cancelled; the composite files it as an
#              infrastructure failure
#   success    the watched job succeeded, yet the notify job files an issue
#   skipped    the watched job was skipped, yet the notify job files an issue
#   non-pr     no arm files on a pull_request run
#
# Every notify job in the scanner workflows (scorecard-drift-check,
# zizmor-drift-check, octoscan, codeql and image-cve-scan) must carry one
# marker in its own issue `body:`, where an HTML comment does not render,
# and at least one in the Markdown docs. A marker naming any other
# workflow's notify job is checked the same way. A docs marker that
# declares `cancelled` must share its paragraph with the word "cancel" in
# some form, because the cancelled arm is the one prose kept dropping. The
# body is exempt from that word, because the composite prefixes a cancelled
# run's issue with its own notice.
#
# Docs are read as paragraphs, split at blank lines and at list-item
# starts. A marker cannot open a line, at any indent: a comment there
# starts an HTML block, which cuts it off from the paragraph it describes
# (and, in a list item, can swallow the item after it).
# Fenced blocks and inline code spans are skipped, which is how a document
# shows the marker without declaring anything.
#
# The gate grammar is the one these workflows use: `always()`, the
# operators `==`, `!=`, `!`, `&&`, `||`, parentheses, quoted strings,
# `github.event_name`, and the watched job's `result` and
# `outputs.has-finding`. A gate without `always()` carries GitHub's
# implicit `success()`. The composite's own result handling (failure and
# cancelled file, success closes, skipped does nothing) is taken as fixed,
# and its classifying lines are checked verbatim so a change to them stops
# this lint rather than silently changing what an arm means.
#
# Exit codes: 0 every marker matches its job's derived arms and every
# scanner notify job carries its markers, 1 a marker disagrees with the
# derived arms, names a job that is not a notify job, is malformed, opens a
# line, sits in the wrong body, or a docs marker declaring cancelled has no
# cancel word near it, or a scanner notify job is missing a marker or files
# on no arm (details printed to stderr), 2 the check could not run: a
# required tool is missing, the composite or a scanner workflow is missing
# or has changed shape, a workflow cannot be parsed, a job it must derive
# has a gate, `needs:` or `result:` outside the grammar, a scanner workflow
# has no notify job, the scan set could not be listed or is empty, or a
# scanned file leaves a code fence or HTML comment open

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

require_tool git
require_tool yq
require_tool awk
require_tool sort

if ! REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'notify-arms: not inside a git repository\n' >&2
  exit 2
fi
readonly REPO_ROOT

# Env override (test-only):
#   SCAN_ROOT_OVERRIDE — alternate root holding the prose to scan, its
#                        own .github/workflows/ and its own composite
readonly SCAN_ROOT="${SCAN_ROOT_OVERRIDE:-${REPO_ROOT}}"
readonly WORKFLOWS_REL='.github/workflows'
readonly COMPOSITE_REL='.github/actions/notify-workflow-result/action.yml'
readonly -a SCANNER_WORKFLOWS=(
  codeql.yml
  image-cve-scan.yml
  octoscan.yml
  scorecard-drift-check.yml
  zizmor-drift-check.yml
)
# The composite lines the arm model rests on, matched after leading
# whitespace is trimmed.
readonly -a COMPOSITE_LINES=(
  "const cancelled = result === 'cancelled';"
  "if (result !== 'success' && result !== 'failure' && !cancelled) {"
  "if (result === 'success') {"
)

function die2() {
  printf 'notify-arms: %s\n' "$1" >&2
  exit 2
}

# @description Fail unless every line the arm model rests on is still in
#              the composite, word for word.
function check_composite() {
  local composite="${SCAN_ROOT}/${COMPOSITE_REL}" want
  [[ -f ${composite} ]] || die2 "missing ${COMPOSITE_REL}"
  for want in "${COMPOSITE_LINES[@]}"; do
    awk -v want="${want}" '
      { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
      line == want { hit = 1 }
      END { exit !hit }
    ' "$(awk_path "${composite}")" ||
      die2 "${COMPOSITE_REL} no longer holds the line \"${want}\"; its result handling changed, so the arm model in this script needs review"
  done
}

# @description Print one record per notify-workflow-result step in a
#              workflow: job id, the watched job (`-` unless `needs:` names
#              exactly one), the `if:` gate (`-` for none) and the
#              `result:` input, with tabs and newlines folded to spaces.
#              Printed raw rather than as TSV, which would quote a field
#              holding a double quote.
# @arg $1 workflow path
# @stdout tab-separated records
function notify_jobs() {
  # shellcheck disable=SC2016 # $job, $j and $n are yq variables
  yq -r '
    .jobs // {} | to_entries | .[] | .key as $job | .value as $j
    | ($j.needs | [.] | flatten) as $n
    | ($j.steps // [])[]
    | select((.uses // "") | test("^\\./\\.github/actions/notify-workflow-result$"))
    | [$job,
        (($n | select(length == 1) | .[0] | select(tag == "!!str")) // "-"),
        (($j.if // "-") | tostring),
        ((.with.result // "-") | tostring)]
    | map(sub("[\t\n]"; " "; "g")) | join("\t")
  ' "$1"
}

# @description Print the notify step's `body:` input for one job.
# @arg $1 workflow path
# @arg $2 job id
function notify_body() {
  JOB="$2" yq -r '
    .jobs[strenv(JOB)].steps[]
    | select((.uses // "") | test("^\\./\\.github/actions/notify-workflow-result$"))
    | .with.body // ""
  ' "$1"
}

# @description Print whether a job declares a `has-finding` output.
# @arg $1 workflow path
# @arg $2 job id
# @stdout true or false
function declares_has_finding() {
  JOB="$2" yq -r '.jobs[strenv(JOB)].outputs // {} | has("has-finding")' "$1"
}

# The gate evaluator. It tokenizes the `if:` expression once, then
# evaluates it for each result x has-finding x event combination. Values
# are "S<text>" for strings and "B1"/"B0" for booleans; string comparison
# is case-insensitive, as in GitHub's expression language.
# shellcheck disable=SC2016
readonly EVAL_AWK='
function fail(msg) { if (err == "") err = msg }
function tokenize(s,   t) {
  n = 0
  while (s != "") {
    if (match(s, /^[[:space:]]+/)) { s = substr(s, RLENGTH + 1); continue }
    if (match(s, /^(==|!=|&&|\|\||!|\(|\))/) ||
        match(s, /^'"'"'[^'"'"']*'"'"'/) ||
        match(s, /^always\(\)/) ||
        match(s, /^[A-Za-z_][A-Za-z0-9_.-]*/)) {
      t = substr(s, 1, RLENGTH)
      s = substr(s, RLENGTH + 1)
      tok[++n] = t
      continue
    }
    fail("unsupported text \"" s "\" in the if: gate")
    return
  }
}
function truthy(v) { return v == "B1" || (substr(v, 1, 1) == "S" && v != "S") }
function prim(   t, v) {
  t = tok[pos]
  if (t == "(") { pos++; v = orx(); if (tok[pos] != ")") fail("unbalanced parentheses in the if: gate"); pos++; return v }
  if (t ~ /^'"'"'/) { pos++; return "S" substr(t, 2, length(t) - 2) }
  if (t == "always()") { pos++; return "B1" }
  if (t == "github.event_name") { pos++; return "S" EVENT }
  if (t == "needs." NEEDS ".result") { pos++; return "S" RESULT }
  if (t == "needs." NEEDS ".outputs.has-finding") { pos++; return "S" HF }
  fail("unsupported operand \"" t "\" in the if: gate (the watched job is " NEEDS ")")
  pos++
  return "B0"
}
function cmp(   a, b, op) {
  a = prim()
  op = tok[pos]
  if (op != "==" && op != "!=") return a
  pos++
  b = prim()
  if (substr(a, 1, 1) != "S" || substr(b, 1, 1) != "S") { fail("comparison of a non-string in the if: gate"); return "B0" }
  return ((tolower(a) == tolower(b)) == (op == "==")) ? "B1" : "B0"
}
function notx() { if (tok[pos] == "!") { pos++; return truthy(notx()) ? "B0" : "B1" } ; return cmp() }
function andx(   v, w) { v = notx(); while (tok[pos] == "&&") { pos++; w = notx(); v = (truthy(v) && truthy(w)) ? "B1" : "B0" } ; return v }
function orx(   v, w) { v = andx(); while (tok[pos] == "||") { pos++; w = andx(); v = (truthy(v) || truthy(w)) ? "B1" : "B0" } ; return v }
function gate(   v) {
  if (n == 0) return RESULT == "success"
  pos = 1
  v = orx()
  if (pos <= n) fail("trailing text \"" tok[pos] "\" in the if: gate")
  return truthy(v) && (implicit ? RESULT == "success" : 1)
}
BEGIN {
  expr = GATE
  if (expr == "-") expr = ""
  if (match(expr, /^[[:space:]]*\$\{\{/) && match(expr, /\}\}[[:space:]]*$/)) {
    sub(/^[[:space:]]*\$\{\{/, "", expr); sub(/\}\}[[:space:]]*$/, "", expr)
  }
  tokenize(expr)
  implicit = 1
  for (i = 1; i <= n; i++) if (tok[i] == "always()") implicit = 0
  if (RESULTIN == "${{ needs." NEEDS ".result }}") filed_raw = 1
  else if (RESULTIN ~ /^(success|failure|cancelled|skipped)$/) filed_raw = 0
  else fail("unsupported result: input \"" RESULTIN "\"")
  split("success failure cancelled skipped", results, " ")
  nhf = split(HASOUT == "true" ? "true|" : "", hfs, "|")
  if (nhf == 0) { nhf = 1; hfs[1] = "" }
  split("pull_request push", events, " ")
  for (r = 1; r <= 4 && err == ""; r++)
    for (h = 1; h <= nhf && err == ""; h++)
      for (e = 1; e <= 2 && err == ""; e++) {
        RESULT = results[r]; HF = hfs[h]; EVENT = events[e]
        if (!gate()) continue
        filed = filed_raw ? RESULT : RESULTIN
        if (filed != "failure" && filed != "cancelled") continue
        arm = RESULT
        if (RESULT == "failure" && tolower(HF) == "true") arm = "finding"
        arms[arm] = 1
        if (EVENT == "pull_request") onpr = 1
        any = 1
      }
  if (err != "") { print "ERR\t" err; exit }
  out = ""
  split("finding failure cancelled success skipped", order, " ")
  for (i = 1; i <= 5; i++) if (order[i] in arms) out = out (out == "" ? "" : " ") order[i]
  if (any && !onpr) out = out " non-pr"
  print "OK\t" out
}
'

# @description Derive one notify job's arms.
# @arg $1 workflow path
# @arg $2 job id
# @arg $3 the watched job, or -
# @arg $4 `if:` gate, or -
# @arg $5 `result:` input, or -
# @stdout "OK<TAB><arms>" (arms may be empty) or "ERR<TAB><why>"
function derive_arms() {
  local wf="$1" job="$2" needs="$3" gate="$4" result_in="$5" has_out
  if [[ ${needs} == - ]]; then
    printf 'ERR\tneeds: does not name exactly one job\n'
    return 0
  fi
  has_out="$(declares_has_finding "${wf}" "${needs}")" || return 1
  awk -v GATE="${gate}" -v NEEDS="${needs}" -v RESULTIN="${result_in}" \
    -v HASOUT="${has_out}" "${EVAL_AWK}" </dev/null
}

# @description Emit every scanned Markdown path under SCAN_ROOT,
#              NUL-delimited and sorted. Tracked files plus not-yet-added
#              ones minus anything gitignored, so the pre-commit hook sees a
#              doc on the commit that adds it. The Claude-behavior tree is
#              mostly untracked scratch, so only its tracked files count.
#              tests/fixtures/ carries deliberate violations, and
#              CHANGELOG.md and docs/releases.md record the tree as it
#              stood at the time.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function prose_scan() {
  local rel listing tracked_claude
  listing="$(make_temp)" || return 1
  tracked_claude="$(make_temp)" || {
    rm --force -- "${listing}"
    return 1
  }
  if ! git -C "${SCAN_ROOT}" ls-files -z --cached --others --exclude-standard \
    >"${listing}" ||
    ! git -C "${SCAN_ROOT}" ls-files -z --cached -- .claude >"${tracked_claude}"; then
    rm --force -- "${listing}" "${tracked_claude}"
    return 1
  fi
  {
    while IFS= read -r -d '' rel; do
      case "${rel}" in
      .claude/* | tests/fixtures/* | CHANGELOG.md | docs/releases.md) continue ;;
      *.md)
        [[ -f ${SCAN_ROOT}/${rel} ]] && printf '%s\0' "${SCAN_ROOT}/${rel}"
        ;;
      esac
    done <"${listing}"
    while IFS= read -r -d '' rel; do
      case "${rel}" in
      *.md) [[ -f ${SCAN_ROOT}/${rel} ]] && printf '%s\0' "${SCAN_ROOT}/${rel}" ;;
      esac
    done <"${tracked_claude}"
  } | sort --zero-terminated
  rm --force -- "${listing}" "${tracked_claude}"
}

# @description Emit every workflow file under SCAN_ROOT, NUL-delimited and
#              sorted.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function workflow_scan() {
  local f
  for f in "${SCAN_ROOT}/${WORKFLOWS_REL}"/*.yml "${SCAN_ROOT}/${WORKFLOWS_REL}"/*.yaml; do
    if [[ -f ${f} ]]; then printf '%s\0' "${f}"; fi
  done | sort --zero-terminated
}

# The marker reader. For each marker in prose it prints
# "M<TAB>line<TAB>workflow<TAB>job<TAB>sorted tokens<TAB>cancel word 0/1";
# problems go to stderr and set the found flag in the closing tally line
# "T<TAB>markers<TAB>found<TAB>unterminated".
# shellcheck disable=SC2016
readonly MARKER_AWK='
function blank(s, from, to,   i, out, c) {
  out = substr(s, 1, from - 1)
  for (i = from; i <= to; i++) { c = substr(s, i, 1); out = out (c == "\n" ? "\n" : " ") }
  return out substr(s, to + 1)
}
# Blank every inline code span. A span opens on a run of n backticks and
# closes on the next run of exactly n; an opener with no closer, or one
# escaped with a backslash, is literal text.
function strip_spans(s,   i, j, n, m, len) {
  len = length(s)
  i = 1
  while (i <= len) {
    if (substr(s, i, 1) != "`") { i++; continue }
    if (i > 1 && substr(s, i - 1, 1) == "\\") { i++; continue }
    n = 0
    while (substr(s, i + n, 1) == "`") n++
    j = i + n
    while (j <= len) {
      if (substr(s, j, 1) != "`") { j++; continue }
      m = 0
      while (substr(s, j + m, 1) == "`") m++
      if (m == n) break
      j += m
    }
    if (j > len) { i += n; continue }
    s = blank(s, i, j + n - 1)
    i = j + n
  }
  return s
}
# Whether a comment reads as an attempt at a marker: one that opens with
# the marker word, allowing a space or underscore slip. A comment that only
# mentions it later (an enforcer note naming check-notify-arms) is not one.
function is_markerish(c) { return tolower(c) ~ /^<!--[[:space:]]*notify[-_[:space:]]*arms?([^a-z]|$)/ }
function line_of(off,   pre) { pre = substr(para, 1, off - 1); return pstart + gsub(/\n/, "", pre) }
function report(off, msg) { printf "%s:%d: %s\n", name, line_of(off), msg > "/dev/stderr"; found = 1 }
function flush(   s, plain, rest, base, k, m, cstart, cend, body, spec, wf, job, toks, nt, t, i, seen, sorted, cw, nm, mline, mwf, mjob, mtoks) {
  if (para == "") return
  s = strip_spans(para)
  # The paragraph with every comment removed: the text a reader sees,
  # code spans included, which is where the cancel word has to be.
  plain = para
  while ((k = index(plain, "<!--")) > 0) {
    m = index(substr(plain, k + 4), "-->")
    if (m == 0) break
    plain = substr(plain, 1, k - 1) " " substr(plain, k + 4 + m + 2)
  }
  cw = (tolower(plain) ~ /cancel/) ? 1 : 0
  nm = 0
  base = 0
  rest = s
  while ((k = index(rest, "<!--")) > 0) {
    cstart = base + k
    m = index(substr(rest, k + 4), "-->")
    if (m == 0) {
      body = substr(s, cstart); sub(/\n.*$/, "", body)
      if (is_markerish(body)) report(cstart, "unclosed notify-arms marker " body)
      base = cstart + 3; rest = substr(s, cstart + 4)
      continue
    }
    cend = cstart + 4 + m + 1
    body = substr(s, cstart, cend - cstart + 1)
    base = cend
    rest = substr(s, cend + 1)
    if (!is_markerish(body)) continue
    if (body ~ /\n/) { report(cstart, "notify-arms marker spans lines; keep it on one line"); continue }
    if (!match(body, /^<!--[[:space:]]*notify-arms[[:space:]]*:[[:space:]]*[A-Za-z0-9._-]+\.ya?ml\/[A-Za-z0-9_-]+[[:space:]]*=[[:space:]]*[a-z-]+([[:space:]]+[a-z-]+)*[[:space:]]*-->$/)) {
      report(cstart, "malformed notify-arms marker " body "; write <!-- notify-arms: <workflow>.yml/<job> = <arm> ... -->")
      continue
    }
    spec = body
    sub(/^<!--[[:space:]]*notify-arms[[:space:]]*:[[:space:]]*/, "", spec)
    sub(/[[:space:]]*-->$/, "", spec)
    wf = spec; sub(/\/.*$/, "", wf)
    job = spec; sub(/^[^\/]*\//, "", job); sub(/[[:space:]]*=.*$/, "", job)
    toks = spec; sub(/^[^=]*=[[:space:]]*/, "", toks)
    nt = split(toks, t, /[[:space:]]+/)
    delete seen
    bad = 0
    for (i = 1; i <= nt; i++) {
      if (t[i] !~ /^(finding|failure|cancelled|success|skipped|non-pr)$/) { report(cstart, "unknown arm \"" t[i] "\" in " body); bad = 1 }
      else if (t[i] in seen) { report(cstart, "arm \"" t[i] "\" repeated in " body); bad = 1 }
      seen[t[i]] = 1
    }
    if (bad) continue
    sorted = ""
    split("finding failure cancelled success skipped non-pr", ord, " ")
    for (i = 1; i <= 6; i++) if (ord[i] in seen) sorted = sorted (sorted == "" ? "" : " ") ord[i]
    nm++
    mline[nm] = line_of(cstart); mwf[nm] = wf; mjob[nm] = job; mtoks[nm] = sorted
  }
  for (i = 1; i <= nm; i++) { printf "M\t%d\t%s\t%s\t%s\t%d\n", mline[i], mwf[i], mjob[i], mtoks[i], cw; markers++ }
  para = ""
}
comment {
  if (index($0, "-->")) comment = 0
  next
}
# A backtick fence info string cannot hold a backtick, so a line opening
# with an inline span is prose, not a fence.
match($0, /^[[:space:]]*(>[[:space:]]*)*(`{3,}|~{3,})/) &&
  (fence || substr($0, RSTART + RLENGTH - 1, 1) == "~" ||
  substr($0, RSTART + RLENGTH) !~ /`/) {
  mk = substr($0, RSTART, RLENGTH)
  # After the marker is read: flush() runs match() of its own, which
  # overwrites RSTART and RLENGTH.
  flush()
  sub(/^[[:space:]]*(>[[:space:]]*)*/, "", mk)
  ch = substr(mk, 1, 1)
  if (!fence) { fence = 1; fch = ch; flen = length(mk) }
  else if (ch == fch && length(mk) >= flen) { fence = 0 }
  next
}
fence { next }
# A comment that opens a line starts an HTML block, which ends the
# paragraph before it, so a marker there describes nothing. Up to three
# spaces in is the CommonMark rule; inside a list item the three count from
# the content column of the item, so any indent reads as opening the line.
/^[[:space:]]*(>[[:space:]]*)*<!--/ {
  flush()
  if (is_markerish(substr($0, index($0, "<!--")))) {
    printf "%s:%d: notify-arms marker opens a line, which cuts it off from its paragraph; move it after text on the same line\n", name, FNR > "/dev/stderr"
    found = 1
  }
  if (index(substr($0, index($0, "<!--") + 4), "-->") == 0) { comment = 1; comment_line = FNR }
  next
}
/^[[:space:]]*$/ { flush(); next }
/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ { flush() }
{
  if (para == "") { para = $0; pstart = FNR }
  else para = para "\n" $0
}
END {
  flush()
  if (fence) printf "%s: unterminated code fence\n", name > "/dev/stderr"
  if (comment) printf "%s:%d: unterminated HTML comment\n", name, comment_line > "/dev/stderr"
  printf "T\t%d\t%d\t%d\n", markers, found, fence || comment
}
'

# @description Run the marker reader over one file.
# @arg $1 file to read
# @arg $2 name to report it under
# @stdout the reader's records
function read_markers() {
  awk -v name="$2" "${MARKER_AWK}" "$(awk_path "$1")"
}

function main() {
  check_composite
  [[ -d "${SCAN_ROOT}/${WORKFLOWS_REL}" ]] || die2 "missing ${WORKFLOWS_REL}"

  local -a workflows=() docs=()
  enumerate_into workflows 'list workflows' workflow_scan
  enumerate_into docs 'list prose' prose_scan

  # Every notify job, keyed "<workflow file>/<job>", with its raw fields.
  local -A job_fields=() derived=() required=()
  local wf base rec job needs gate result_in
  for wf in "${workflows[@]}"; do
    base="${wf##*/}"
    local listing
    listing="$(notify_jobs "${wf}")" || die2 "cannot parse ${WORKFLOWS_REL}/${base}"
    while IFS= read -r rec; do
      # yq prints empty lines between records; anything else must be a
      # whole four-field record.
      [[ -n ${rec} ]] || continue
      [[ ${rec} =~ ^[^$'\t']+$'\t'[^$'\t']+$'\t'[^$'\t']+$'\t'[^$'\t']+$ ]] ||
        die2 "unreadable notify record in ${WORKFLOWS_REL}/${base}: ${rec}"
      IFS=$'\t' read -r job needs gate result_in <<<"${rec}"
      job_fields["${base}/${job}"]="${needs}"$'\t'"${gate}"$'\t'"${result_in}"
    done <<<"${listing}"
  done

  local s found_job
  for s in "${SCANNER_WORKFLOWS[@]}"; do
    [[ -f "${SCAN_ROOT}/${WORKFLOWS_REL}/${s}" ]] || die2 "missing scanner workflow ${WORKFLOWS_REL}/${s}"
    found_job=0
    for rec in "${!job_fields[@]}"; do
      if [[ ${rec%%/*} == "${s}" ]]; then
        required["${rec}"]=1
        found_job=1
      fi
    done
    ((found_job)) || die2 "scanner workflow ${WORKFLOWS_REL}/${s} has no notify-workflow-result job"
  done

  # @description Derive and memoize one job's arms into ARMS; exit 2 on a
  #              gate the grammar cannot read. Called outside a command
  #              substitution, so the memo and the exit both reach main.
  function arms_of() {
    local key="$1" out
    if [[ -z ${derived["${key}"]+set} ]]; then
      IFS=$'\t' read -r needs gate result_in <<<"${job_fields["${key}"]}"
      out="$(derive_arms "${SCAN_ROOT}/${WORKFLOWS_REL}/${key%%/*}" "${key#*/}" \
        "${needs}" "${gate}" "${result_in}")" ||
        die2 "cannot read ${WORKFLOWS_REL}/${key}"
      [[ ${out} == OK$'\t'* ]] || die2 "${WORKFLOWS_REL}/${key%%/*}: job ${key#*/}: ${out#ERR$'\t'}"
      derived["${key}"]="${out#OK$'\t'}"
    fi
    ARMS="${derived["${key}"]}"
  }

  local -i found=0 body_markers=0 doc_markers=0 unterminated=0
  local -A body_seen=() doc_seen=()
  local tag line mwf mjob mtoks cw key want tally rc_out tmp ARMS=''
  tmp="$(make_temp)" || die2 'cannot create a temporary file'

  # @description Check one marker record against the derived arms.
  function check_marker() {
    local where="$1" origin="$2" own="$3"
    key="${mwf}/${mjob}"
    if [[ -z ${job_fields["${key}"]+set} ]]; then
      printf '%s: marker names %s, which is not a notify-workflow-result job\n' "${where}" "${key}" >&2
      found=1
      return 0
    fi
    if [[ ${origin} == body && ${key} != "${own}" ]]; then
      printf '%s: marker in the body of %s names %s\n' "${where}" "${own}" "${key}" >&2
      found=1
      return 0
    fi
    arms_of "${key}"
    want="${ARMS}"
    # Counted before any verdict: a job with a wrong marker still has one.
    if [[ ${origin} == body ]]; then
      body_seen["${key}"]=1
      body_markers+=1
    else
      doc_seen["${key}"]=1
      doc_markers+=1
    fi
    if [[ -z ${want} ]]; then
      printf '%s: %s files on no arm; its gate admits no failure or cancelled result\n' "${where}" "${key}" >&2
      found=1
      return 0
    fi
    if [[ ${mtoks} != "${want}" ]]; then
      printf '%s: marker for %s declares "%s"; the workflow files on "%s"\n' \
        "${where}" "${key}" "${mtoks}" "${want}" >&2
      found=1
    fi
    if [[ ${origin} == doc && " ${mtoks} " == *" cancelled "* && ${cw} == 0 ]]; then
      printf '%s: marker for %s declares cancelled, but its paragraph never says so; name the cancelled job in the prose\n' \
        "${where}" "${key}" >&2
      found=1
    fi
  }

  # @description Read one file's markers and check each.
  function scan_file() {
    local path="$1" name="$2" origin="$3" own="$4"
    rc_out="$(read_markers "${path}" "${name}")" || die2 "scan failed for ${name}"
    tally=''
    while IFS=$'\t' read -r tag line mwf mjob mtoks cw; do
      case "${tag}" in
      M) check_marker "${name}:${line}" "${origin}" "${own}" ;;
      T)
        tally="${line}"
        # For a T record the fields are markers, found, unterminated.
        ((mwf)) && found=1
        ((mjob)) && unterminated=1
        ;;
      esac
    done <<<"${rc_out}"
    [[ -n ${tally} ]] || die2 "scan of ${name} produced no tally"
  }

  for key in "${!job_fields[@]}"; do
    notify_body "${SCAN_ROOT}/${WORKFLOWS_REL}/${key%%/*}" "${key#*/}" >"${tmp}" ||
      die2 "cannot read the body of ${WORKFLOWS_REL}/${key}"
    scan_file "${tmp}" "${WORKFLOWS_REL}/${key%%/*} (job ${key#*/} body)" body "${key}"
  done
  local f
  for f in "${docs[@]}"; do
    scan_file "${f}" "${f#"${SCAN_ROOT}"/}" doc ''
  done
  rm --force -- "${tmp}"

  if ((unterminated)); then
    printf 'notify-arms: a scanned file left a code fence or HTML comment open, so the rest of it went unread.\n' >&2
    exit 2
  fi

  local -a missing=()
  for key in "${!required[@]}"; do
    [[ -n ${body_seen["${key}"]+set} ]] || missing+=("${WORKFLOWS_REL}/${key%%/*}: job ${key#*/} has no notify-arms marker in its issue body")
    [[ -n ${doc_seen["${key}"]+set} ]] || missing+=("${WORKFLOWS_REL}/${key%%/*}: job ${key#*/} has no notify-arms marker in the docs")
    # A required job with no marker at all is still derived, so a gate the
    # grammar cannot read stops the run rather than hiding behind the gap.
    arms_of "${key}"
    [[ -n ${ARMS} ]] || missing+=("${WORKFLOWS_REL}/${key%%/*}: job ${key#*/} files on no arm; its gate admits no failure or cancelled result")
  done
  if ((${#missing[@]})); then
    printf '%s\n' "${missing[@]}" | LC_ALL=C sort >&2
    found=1
  fi

  if ((found)); then
    printf 'notify-arms: a stated notify arm list disagrees with its workflow, is malformed, or is missing; derive the arms from the notify job'"'"'s if: gate and result: input, then fix the prose and its marker.\n' >&2
    exit 1
  fi

  # The derived arms, tallied over the scanner jobs, are what tells a
  # clean tree from one where every gate derived the same wrong set.
  local -A tally_of=()
  local arm
  for key in "${!required[@]}"; do
    arms_of "${key}"
    for arm in ${ARMS//' '/$'\n'}; do
      tally_of["${arm}"]=$((${tally_of["${arm}"]:-0} + 1))
    done
  done
  local tallies=''
  for arm in finding failure cancelled success skipped non-pr; do
    tallies+="${tallies:+ }${arm}=${tally_of["${arm}"]:-0}"
  done
  printf 'check-notify-arms: ok — %d body marker(s) and %d docs marker(s) match the arms of %d scanner notify job(s) (%s); scanned %d workflow(s) and %d Markdown file(s)\n' \
    "${body_markers}" "${doc_markers}" "${#required[@]}" "${tallies}" "${#workflows[@]}" "${#docs[@]}"
}

main "$@"
