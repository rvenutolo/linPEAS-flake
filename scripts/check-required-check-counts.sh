#!/usr/bin/env bash
# scripts/check-required-check-counts.sh
#
# @description Lint: every count of the required-check set stated in prose
# must equal the number of data rows in the `## Required contexts` table of
# docs/security/required-checks.md. That table is the canonical set, and
# nothing generates the sentences that restate its size, so a context added
# to or removed from the ruleset leaves each of them silently wrong.
#
# A count is declared, not guessed. A prose count carries a marker comment
# directly after its number:
#
#   Every PR must pass 27 <!-- count: required-contexts --> required status
#   checks.
#
# The number immediately before the marker is the claim, so a paragraph that
# states two numbers stays unambiguous. The marker must follow ASCII digits;
# a number word, a missing number or an unknown key is reported rather than
# skipped, because a marker that resolves to nothing is a count nobody
# checks.
#
# A backstop catches a count written without a marker: a number, in digits
# or as a word, followed within two words by "required check(s)", "required
# status check(s)" or "required context(s)". Anything wider matched unrelated
# numbers on the real tree (a cron time, a sentence counting something else),
# so other phrasings of the count are not seen. A subset count in the
# backstop's shape is reported too, since a marker cannot name a subset;
# rephrase it.
#
# Paragraphs are read with their lines joined, so a count wrapped across a
# line break is still one phrase. Fenced blocks and inline code spans are
# skipped, which is how a document shows the marker or the phrase without
# making a claim. Fences are tracked marker-aware, as in
# check-prose-ci-names.sh, and a file ending inside a fence is a precondition
# failure.
#
# Exit codes: 0 every declared count matches the table and no undeclared
# count was found, 1 a count disagrees with the table, is undeclared, or
# carries a malformed marker (details printed to stderr), 2 the check could
# not run: a required tool is missing, the table is missing, duplicated or
# empty, the scan set could not be listed or is empty, or a scanned file
# leaves a code fence open

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
require_tool awk
require_tool sort

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

# Env override (test-only):
#   SCAN_ROOT_OVERRIDE — alternate root holding the prose to scan and its
#                        own docs/security/required-checks.md
readonly SCAN_ROOT="${SCAN_ROOT_OVERRIDE:-${REPO_ROOT}}"
readonly TABLE_DOC_REL='docs/security/required-checks.md'
readonly TABLE_DOC="${SCAN_ROOT}/${TABLE_DOC_REL}"

# @description Print the number of data rows in the `## Required contexts`
#              table. A table starts at the section's first `|` line, whose
#              next line must be the `| ---` separator, and ends at the first
#              line that is not a `|` line.
# @stdout the row count
# @exitcode 0 the section holds exactly one well-formed table
# @exitcode 3 no such section
# @exitcode 4 more than one such section
# @exitcode 5 no table in the section
# @exitcode 6 the table has no separator row under its header
# @exitcode 7 a second table in the section
function count_table_rows() {
  awk '
    /^## / {
      in_sec = ($0 == "## Required contexts")
      if (in_sec) headings++
      state = 0
      next
    }
    !in_sec { next }
    state == 0 && /^\|/ { if (tables++) extra = 1; state = 1; next }
    state == 1 {
      if ($0 !~ /^\|[-|: ]+\|[[:space:]]*$/) nosep = 1
      state = 2
      next
    }
    state == 2 && /^\|/ { rows++; next }
    state == 2 { state = 0 }
    END {
      if (headings == 0) exit 3
      if (headings > 1) exit 4
      if (tables == 0) exit 5
      if (nosep) exit 6
      if (extra) exit 7
      print rows + 0
    }
  ' "$(awk_path "${TABLE_DOC}")"
}

# @description Emit every scanned Markdown path under SCAN_ROOT,
#              NUL-delimited and sorted. Tracked files plus not-yet-added
#              ones minus anything gitignored, so the pre-commit hook sees a
#              doc on the commit that adds it. The Claude-behavior tree is
#              mostly untracked scratch, so only its tracked files count.
#              tests/fixtures/ carries deliberate violations, and
#              CHANGELOG.md and docs/releases.md record counts as they
#              stood at the time.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function prose_scan() {
  local rel listing tracked_claude
  listing="$(make_temp)" || return 1
  tracked_claude="$(make_temp)" || {
    rm --force -- "${listing}"
    return 1
  }
  # Listed into files rather than process substitutions, so a git failure
  # is seen here instead of reading as an empty tree.
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
      *.md) printf '%s\0' "${SCAN_ROOT}/${rel}" ;;
      esac
    done <"${listing}"
    while IFS= read -r -d '' rel; do
      case "${rel}" in
      *.md) printf '%s\0' "${SCAN_ROOT}/${rel}" ;;
      esac
    done <"${tracked_claude}"
  } | sort --zero-terminated
  rm --force -- "${listing}" "${tracked_claude}"
}

function main() {
  [[ -f ${TABLE_DOC} ]] || {
    printf 'required-check-counts: missing %s\n' "${TABLE_DOC}" >&2
    exit 2
  }
  local expected why
  local -i rc=0
  expected="$(count_table_rows)" || rc=$?
  if ((rc)); then
    case "${rc}" in
    3) why='has no "## Required contexts" section' ;;
    4) why='has more than one "## Required contexts" section' ;;
    5) why='has no table under "## Required contexts"' ;;
    6) why='has a Required contexts table with no separator row under its header' ;;
    7) why='has a second table under "## Required contexts"' ;;
    *) why='could not be read' ;;
    esac
    printf 'required-check-counts: %s %s\n' "${TABLE_DOC_REL}" "${why}" >&2
    exit 2
  fi
  ((expected > 0)) || {
    printf 'required-check-counts: the Required contexts table in %s has no data rows\n' \
      "${TABLE_DOC_REL}" >&2
    exit 2
  }

  local -a files=()
  enumerate_into files 'list prose' prose_scan

  local awk_prog
  awk_prog=$(
    cat <<'AWK'

      # @description Overwrite s[from..to] with filler, keeping newlines, so
      #              every offset still maps to the same line.
      function blank(s, from, to,   i, out, c) {
        out = substr(s, 1, from - 1)
        for (i = from; i <= to; i++) {
          c = substr(s, i, 1)
          out = out (c == "\n" ? "\n" : " ")
        }
        return out substr(s, to + 1)
      }
      # @description Blank every inline code span. A span opens on a run of
      #              n backticks and closes on the next run of exactly n; an
      #              opener with no closer is literal text.
      function strip_spans(s,   i, j, n, m, len) {
        len = length(s)
        i = 1
        while (i <= len) {
          if (substr(s, i, 1) != "`") { i++; continue }
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
      # @description Line number of offset off within the paragraph.
      function line_of(off,   pre) {
        pre = substr(para, 1, off - 1)
        return pstart + gsub(/\n/, "", pre)
      }
      function report(off, msg) {
        printf "%s:%d: %s\n", name, line_of(off), msg > "/dev/stderr"
        found = 1
      }
      function flush(   s, low, phrase, tok, rest, base, mstart, mlen, body, key, pre, k, dstart, val) {
        if (para == "") return
        paras++
        s = strip_spans(para)
        # Declared counts. Every comment opening with `count:` is a marker,
        # so a misspelt key is reported instead of read as an ordinary
        # comment.
        base = 0
        rest = s
        while (match(rest, /<!--[[:space:]]*count[[:space:]]*:[^>]*-->/)) {
          mstart = base + RSTART
          mlen = RLENGTH
          body = substr(rest, RSTART, RLENGTH)
          base = mstart + mlen - 1
          rest = substr(rest, RSTART + RLENGTH)
          key = body
          sub(/^<!--[[:space:]]*count[[:space:]]*:[[:space:]]*/, "", key)
          sub(/[[:space:]]*-->$/, "", key)
          if (key != "required-contexts") {
            report(mstart, "unknown count marker key \"" key "\" (the only key is required-contexts)")
            continue
          }
          # The digits directly before the marker, past any whitespace.
          pre = substr(s, 1, mstart - 1)
          sub(/[[:space:]]+$/, "", pre)
          k = length(pre)
          while (k > 0 && substr(pre, k, 1) ~ /[0-9]/) k--
          dstart = k + 1
          if (dstart > length(pre) || (k > 0 && substr(pre, k, 1) ~ /[A-Za-z_-]/)) {
            tok = pre
            sub(/^.*[[:space:]]/, "", tok)
            report(mstart, "count marker follows \"" tok "\", not a number written in digits")
            continue
          }
          val = substr(pre, dstart) + 0
          sites++
          if (val != expected)
            report(mstart, "states " val " required contexts; " table " has " expected)
        }
        # Undeclared counts. Matched on a lowercased copy, which keeps every
        # offset, so a sentence-initial number word is still seen.
        low = tolower(s)
        base = 0
        rest = low
        while (match(rest, BACKSTOP)) {
          mstart = base + RSTART
          # The match may open on the boundary character before the number
          # and close on the one after the noun; quote the phrase alone.
          phrase = substr(para, mstart, RLENGTH)
          if (substr(low, mstart, 1) ~ /[^a-z0-9]/) { phrase = substr(phrase, 2); mstart++ }
          if (substr(phrase, length(phrase), 1) ~ /[^A-Za-z]/) phrase = substr(phrase, 1, length(phrase) - 1)
          gsub(/[[:space:]]+/, " ", phrase)
          report(mstart, "undeclared required-check count \"" phrase "\"; add <!-- count: required-contexts --> after the number, or rephrase a subset count")
          backstop++
          base = base + RSTART + RLENGTH - 1
          rest = substr(rest, RSTART + RLENGTH)
        }
        para = ""
      }
      BEGIN {
        W = "(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)(-[a-z]+)?"
        NUM = "([0-9]+|" W ")"
        GAP = "([a-z0-9_-]+[[:space:]]+)?([a-z0-9_-]+[[:space:]]+)?"
        BACKSTOP = "(^|[^a-z0-9_-])" NUM "[[:space:]]+" GAP "required[[:space:]]+(status[[:space:]]+)?(checks?|contexts?)([^a-z0-9_-]|$)"
      }
      match($0, /^[[:space:]]*(>[[:space:]]*)*(`{3,}|~{3,})/) {
        mk = substr($0, RSTART, RLENGTH)
        # After the marker is read: flush() runs match() of its own, which
        # overwrites RSTART and RLENGTH.
        flush()
        sub(/^[[:space:]]*(>[[:space:]]*)*/, "", mk)
        ch = substr(mk, 1, 1)
        if (!fence) { fence = 1; fch = ch; flen = length(mk) }
        else if (ch == fch && length(mk) >= flen) { fence = 0 }
        fenced++
        next
      }
      fence { fenced++; next }
      /^[[:space:]]*$/ { flush(); next }
      {
        lines++
        if (para == "") { para = $0; pstart = FNR }
        else para = para "\n" $0
      }
      END {
        flush()
        if (fence) printf "%s: unterminated code fence\n", name > "/dev/stderr"
        printf "%d\t%d\t%d\t%d\t%d\t%d\n", lines, fenced, sites, backstop, found, fence
      }
AWK
  )

  local -i lines=0 fenced=0 sites=0 backstop=0 found=0 unterminated=0
  local f report
  local -i f_lines f_fenced f_sites f_backstop f_found f_unterminated
  for f in "${files[@]}"; do
    if ! report="$(
      awk -v expected="${expected}" -v table="${TABLE_DOC_REL}" \
        -v name="${f#"${SCAN_ROOT}"/}" \
        "${awk_prog}" "$(awk_path "${f}")"
    )"; then
      printf 'required-check-counts: scan failed for %s\n' "${f}" >&2
      exit 2
    fi
    IFS=$'\t' read -r f_lines f_fenced f_sites f_backstop f_found \
      f_unterminated <<<"${report}"
    lines=$((lines + f_lines))
    fenced=$((fenced + f_fenced))
    sites=$((sites + f_sites))
    backstop=$((backstop + f_backstop))
    found=$((found + f_found))
    unterminated=$((unterminated + f_unterminated))
  done

  if ((unterminated)); then
    printf 'required-check-counts: a scanned file left a code fence open, so the rest of it went unread.\n' >&2
    exit 2
  fi
  if ((found)); then
    printf 'required-check-counts: a prose count of the required set is wrong, undeclared or malformed; the set is the %d data row(s) of the Required contexts table in %s.\n' \
      "${expected}" "${TABLE_DOC_REL}" >&2
    exit 1
  fi

  # The site count is what separates a tree whose counts all match from one
  # where no marker was read at all.
  printf 'check-required-check-counts: ok — %d declared count(s) match %d required context(s); scanned %d file(s), %d prose line(s) (%d fenced line(s) skipped)\n' \
    "${sites}" "${expected}" "${#files[@]}" "${lines}" "${fenced}"
}

main "$@"
