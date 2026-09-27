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
require_tool sha256sum

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
# SHA-256 of the composite from its `runs:` line through the line that
# opens its success branch: the input wiring and every line that decides
# whether a result files, closes or does nothing. Update it only after
# checking that the arm model below still describes the composite.
readonly COMPOSITE_SHA256='28fe77a370006e9d4e68faf5526a863f11f1e69b7f4ba1066b3339420c36ad9f'

function die2() {
  printf 'notify-arms: %s\n' "$1" >&2
  exit 2
}

# @description Fail unless the composite's result handling is the one the
#              arm model describes: no step gated by an `if:`, and the text
#              from `runs:` through the success branch hashing to the pin.
function check_composite() {
  local composite="${SCAN_ROOT}/${COMPOSITE_REL}" gated prefix sum
  [[ -f ${composite} ]] || die2 "missing ${COMPOSITE_REL}"
  gated="$(yq -r '[.runs.steps // [] | .[] | select(has("if"))] | length' "${composite}")" ||
    die2 "cannot parse ${COMPOSITE_REL}"
  [[ ${gated} == 0 ]] ||
    die2 "${COMPOSITE_REL} gates its step with an if:, so a result can skip it; the arm model in this script needs review"
  prefix="$(make_temp)" || die2 'cannot create a temporary file'
  awk '
    /^runs:[[:space:]]*$/ { on = 1 }
    on { print }
    on && /^[[:space:]]*if \(result === .success.\) \{[[:space:]]*$/ { done = 1; exit }
    END { exit !done }
  ' "$(awk_path "${composite}")" >"${prefix}" || {
    rm --force -- "${prefix}"
    die2 "the result handling of ${COMPOSITE_REL} changed: no runs: section reaching an if (result === 'success') branch"
  }
  sum="$(sha256sum -- "${prefix}")" || die2 "cannot hash ${COMPOSITE_REL}"
  rm --force -- "${prefix}"
  [[ ${sum%% *} == "${COMPOSITE_SHA256}" ]] ||
    die2 "the result handling of ${COMPOSITE_REL} changed (its text from runs: through the success branch no longer matches COMPOSITE_SHA256); review the arm model in this script, then update the pin"
}

# @description Print one record per step in a workflow whose `uses:`
#              names the notify composite in any form: the `uses:` value,
#              job id, the watched job (`-` unless `needs:` names exactly
#              one), the job's `if:` gate (`-` for none), the `result:`
#              input and the step's own `if:` (`-` for none), with tabs and
#              newlines folded to spaces. Printed raw rather than as TSV,
#              which would quote a field holding a double quote.
# @arg $1 workflow path
# @stdout tab-separated records
function notify_jobs() {
  # shellcheck disable=SC2016 # $job, $j and $n are yq variables
  yq -r '
    .jobs // {} | to_entries | .[] | .key as $job | .value as $j
    | ($j.needs | [.] | flatten) as $n
    | ($j.steps // [])[]
    | select((.uses // "") | test("notify-workflow-result"))
    | [(.uses | tostring), $job,
        (($n | select(length == 1) | .[0] | select(tag == "!!str")) // "-"),
        (($j.if // "-") | tostring),
        ((.with.result // "-") | tostring),
        ((.if // "-") | tostring)]
    | map(sub("[\t\n]"; " "; "g")) | join("\t")
  ' "$1"
}

# @description Print the events a workflow runs on, one per line: its
#              `on:` value as a string, the items of a list, or the keys
#              of a map.
# @arg $1 workflow path
function workflow_events() {
  local shape
  shape="$(yq -r '.on | tag' "$1")" || return 1
  case "${shape}" in
  '!!str') yq -r '.on' "$1" ;;
  '!!seq') yq -r '.on[]' "$1" ;;
  '!!map') yq -r '.on | keys | .[]' "$1" ;;
  *) return 1 ;;
  esac
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

# @description Print whether a job declares a `has-finding` output, in any
#              case: GitHub reads context property names case-insensitively.
# @arg $1 workflow path
# @arg $2 job id
# @stdout true or false
function declares_has_finding() {
  JOB="$2" yq -r '.jobs[strenv(JOB)].outputs // {} | keys | map(downcase) | any_c(. == "has-finding")' "$1"
}

# The gate evaluator. It tokenizes the `if:` expression once, then
# evaluates it for each result x has-finding x event combination. Values
# are "S<text>" for strings and "B1"/"B0" for booleans; string comparison
# and context names are case-insensitive, as in GitHub's expression
# language. Its inputs arrive through the environment, because awk -v
# would decode backslash escapes that GitHub compares literally.
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
function prim(   t, v, lt) {
  t = tok[pos]
  lt = tolower(t)
  if (t == "(") { pos++; v = orx(); if (tok[pos] != ")") fail("unbalanced parentheses in the if: gate"); pos++; return v }
  if (t ~ /^'"'"'/) { pos++; return "S" substr(t, 2, length(t) - 2) }
  if (t == "always()") { pos++; return "B1" }
  if (lt == "github.event_name") { pos++; return "S" EVENT }
  if (lt == tolower("needs." NEEDS ".result")) { pos++; return "S" RESULT }
  if (lt == tolower("needs." NEEDS ".outputs.has-finding")) { pos++; return "S" HF }
  fail("unsupported operand \"" t "\" in the if: gate (the watched job is " NEEDS ")")
  pos++
  return "B0"
}
# `!` binds tighter than a comparison, so it applies to one operand.
function unary() { if (tok[pos] == "!") { pos++; return truthy(unary()) ? "B0" : "B1" } ; return prim() }
function cmp(   a, b, op) {
  a = unary()
  op = tok[pos]
  if (op != "==" && op != "!=") return a
  pos++
  b = unary()
  if (substr(a, 1, 1) != "S" || substr(b, 1, 1) != "S") { fail("comparison of a non-string in the if: gate"); return "B0" }
  return ((tolower(a) == tolower(b)) == (op == "==")) ? "B1" : "B0"
}
function andx(   v, w) { v = cmp(); while (tok[pos] == "&&") { pos++; w = cmp(); v = (truthy(v) && truthy(w)) ? "B1" : "B0" } ; return v }
function orx(   v, w) { v = andx(); while (tok[pos] == "||") { pos++; w = andx(); v = (truthy(v) || truthy(w)) ? "B1" : "B0" } ; return v }
function gate(   v) {
  if (n == 0) return RESULT == "success"
  pos = 1
  v = orx()
  if (pos <= n) fail("trailing text \"" tok[pos] "\" in the if: gate")
  return truthy(v) && (implicit ? RESULT == "success" : 1)
}
BEGIN {
  GATE = ENVIRON["NA_GATE"]; NEEDS = ENVIRON["NA_NEEDS"]
  RESULTIN = ENVIRON["NA_RESULTIN"]; HASOUT = ENVIRON["NA_HASOUT"]
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
  # A declared output is true, false or empty; an undeclared one is always
  # empty.
  nhf = split(HASOUT == "true" ? "true|false|" : "", hfs, "|")
  if (nhf == 0) { nhf = 1; hfs[1] = "" }
  # pull_request, which non-pr is about, and every event the workflow
  # names in on:.
  nev = split("pull_request " ENVIRON["NA_EVENTS"], events, " ")
  for (r = 1; r <= 4 && err == ""; r++)
    for (h = 1; h <= nhf && err == ""; h++)
      for (e = 1; e <= nev && err == ""; e++) {
        RESULT = results[r]; HF = hfs[h]; EVENT = events[e]
        if (!gate()) continue
        filed = filed_raw ? RESULT : RESULTIN
        if (filed != "failure" && filed != "cancelled") continue
        arm = RESULT
        if (RESULT == "failure" && HF == "true") arm = "finding"
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
  local wf="$1" job="$2" needs="$3" gate="$4" result_in="$5" has_out events
  if [[ ${needs} == - ]]; then
    printf 'ERR\tneeds: does not name exactly one job\n'
    return 0
  fi
  has_out="$(declares_has_finding "${wf}" "${needs}")" || return 1
  if ! events="$(workflow_events "${wf}")"; then
    printf 'ERR\tthe workflow has no on: trigger the lint can read\n'
    return 0
  fi
  NA_GATE="${gate}" NA_NEEDS="${needs}" NA_RESULTIN="${result_in}" \
    NA_HASOUT="${has_out}" NA_EVENTS="${events//$'\n'/ }" \
    awk "${EVAL_AWK}" </dev/null
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
# the marker word, allowing slips such as an extra dash in the opener or
# any punctuation between the two words. A comment that only mentions it
# later (an enforcer note naming check-notify-arms) is not one.
function is_markerish(c) { return tolower(c) ~ /^<!--[-[:space:]]*notify[^a-z]*arms?([^a-z]|$)/ }
# Report every marker-like comment in text that an HTML block holds rather
# than a paragraph. The first comment of a line that opens with one gets
# its own message, since moving it after text is the usual fix.
function block_markers(text, lineno, opens,   k, first) {
  first = opens
  while ((k = index(text, "<!--")) > 0) {
    text = substr(text, k)
    if (is_markerish(text)) {
      if (first)
        printf "%s:%d: notify-arms marker opens a line, which cuts it off from its paragraph; move it after text on the same line\n", name, lineno > "/dev/stderr"
      else
        printf "%s:%d: notify-arms marker sits on a line an HTML block holds, not in a paragraph; move it into the prose it describes\n", name, lineno > "/dev/stderr"
      found = 1
    }
    first = 0
    text = substr(text, 5)
  }
}
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
  # A link destination is not on the page.
  gsub(/\]\([^)]*\)/, "]", plain)
  gsub(/<[a-z][a-z0-9+.-]*:[^> ]*>/, " ", plain)
  # The word in some form, but not inside a hyphenated compound such as
  # cancel-in-progress, which names a setting rather than the arm.
  cw = (tolower(plain) ~ /(^|[^a-z-])cancel(s|led|ling|lation|ed)?([^a-z-]|$)/) ? 1 : 0
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
# Inside a comment block the rest of the line after its closer still
# belongs to the HTML block.
comment {
  if ((k = index($0, "-->")) > 0) {
    comment = 0
    block_markers(substr($0, k + 3), FNR, 0)
  }
  next
}
# A backtick fence info string cannot hold a backtick, so a line opening
# with an inline span is prose, not a fence.
match($0, /^[[:space:]]*(>[[:space:]]*)*(`{3,}|~{3,})/) &&
  (fence || substr($0, RSTART + RLENGTH - 1, 1) == "~" ||
  substr($0, RSTART + RLENGTH) !~ /`/) {
  mk = substr($0, RSTART, RLENGTH)
  after = substr($0, RSTART + RLENGTH)
  # After the marker is read: flush() runs match() of its own, which
  # overwrites RSTART and RLENGTH.
  flush()
  sub(/^[[:space:]]*(>[[:space:]]*)*/, "", mk)
  ch = substr(mk, 1, 1)
  if (!fence) { fence = 1; fch = ch; flen = length(mk) }
  # A closing fence carries nothing after its marker; one with an info
  # string is a line of the fenced block.
  else if (ch == fch && length(mk) >= flen && after ~ /^[[:space:]]*$/) { fence = 0 }
  next
}
fence { next }
# A comment that opens a line starts an HTML block, which ends the
# paragraph before it, so a marker there describes nothing. Up to three
# spaces in is the CommonMark rule; inside a list item the three count from
# the content column of the item, so any indent reads as opening the line.
# An issue body has no paragraph to lose: every comment there is hidden,
# and no cancel word is asked of it, so a body line is read as prose.
!body && /^[[:space:]]*(>[[:space:]]*)*<!--/ {
  flush()
  rest = substr($0, index($0, "<!--"))
  if (index(substr(rest, 5), "-->") == 0) { comment = 1; comment_line = FNR }
  block_markers(rest, FNR, 1)
  next
}
/^[[:space:]]*$/ { flush(); next }
# A heading and a table row are blocks of their own, so the cancel word
# in one does not speak for a marker in another.
/^ ? ? ?(#{1,6}([[:space:]]|$)|\|)/ {
  flush()
  para = $0; pstart = FNR
  flush()
  next
}
# A setext underline makes the lines above it a heading.
para != "" && /^ ? ? ?(=+|-+)[[:space:]]*$/ {
  para = para "\n" $0
  flush()
  next
}
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
# @arg $3 1 when the file is an issue body, 0 for a doc
# @stdout the reader's records
function read_markers() {
  awk -v name="$2" -v body="$3" "${MARKER_AWK}" "$(awk_path "$1")"
}

function main() {
  check_composite
  [[ -d "${SCAN_ROOT}/${WORKFLOWS_REL}" ]] || die2 "missing ${WORKFLOWS_REL}"

  local -a workflows=() docs=()
  enumerate_into workflows 'list workflows' workflow_scan
  enumerate_into docs 'list prose' prose_scan

  # Every notify job, keyed "<workflow file>/<job>", with its raw fields.
  local -A job_fields=() job_block=() derived=() required=()
  local wf base rec uses job needs gate result_in step_if key
  local -r field=$'[^\t]+'
  for wf in "${workflows[@]}"; do
    base="${wf##*/}"
    local listing
    listing="$(notify_jobs "${wf}")" || die2 "cannot parse ${WORKFLOWS_REL}/${base}"
    while IFS= read -r rec; do
      # yq prints empty lines between records; anything else must be a
      # whole six-field record.
      [[ -n ${rec} ]] || continue
      [[ ${rec} =~ ^${field}$'\t'${field}$'\t'${field}$'\t'${field}$'\t'${field}$'\t'${field}$ ]] ||
        die2 "unreadable notify record in ${WORKFLOWS_REL}/${base}: ${rec}"
      IFS=$'\t' read -r uses job needs gate result_in step_if <<<"${rec}"
      # A job the lint cannot model is refused when it has to be derived,
      # rather than read as if it were simpler than it is. Other
      # workflows may reach the composite at a pinned remote revision,
      # which is only a problem once a marker names such a job.
      key="${base}/${job}"
      if [[ -n ${job_fields["${key}"]+set} ]]; then
        job_block["${key}"]="job ${job} runs more than one notify-workflow-result step, which the lint cannot model"
      elif [[ ${uses} != './.github/actions/notify-workflow-result' ]]; then
        job_block["${key}"]="job ${job} names the notify composite as \"${uses}\"; the lint models only ./.github/actions/notify-workflow-result"
      elif [[ ${step_if} != - ]]; then
        job_block["${key}"]="job ${job}: the notify step carries an if: of its own, which the lint cannot model"
      fi
      job_fields["${key}"]="${needs}"$'\t'"${gate}"$'\t'"${result_in}"
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
      [[ -z ${job_block["${key}"]:-} ]] || die2 "${WORKFLOWS_REL}/${key%%/*}: ${job_block["${key}"]}"
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
    rc_out="$(read_markers "${path}" "${name}" "$([[ ${origin} == body ]] && echo 1 || echo 0)")" ||
      die2 "scan failed for ${name}"
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
