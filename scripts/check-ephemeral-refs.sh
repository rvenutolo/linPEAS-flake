#!/usr/bin/env bash
# scripts/check-ephemeral-refs.sh
#
# @description Lint: every Markdown file, shell script, Nix source and
# YAML source in the repo must carry no ephemeral references — PR/issue
# refs, prose dates, planning/review-pass labels, or literal `.claude/`
# paths.
# Markdown is read as prose; shell is read as comments only, lifted from
# the `shfmt` syntax tree; Nix is read as the comments that start their
# own line, both `#` line comments and `/* */` block comments; YAML is
# read as the `#` comments that start their own line, block scalars
# included.
# Only the sources whose raw text carries a candidate token are
# extracted; the rest are set aside and reported as such.
# Default mode blocks (exit 1); --advisory mode
# suppresses findings, not defects: it warns on fuzzy causal-history
# phrases and exits 0 on those, but a could-not-run (unterminated
# fence/generated block/Nix block comment, unparsable shell, a shell
# scan, a Nix scan or a YAML scan that extracted no comments, a failed candidate
# scan, a structural pass that read fewer sources than were set aside
# for it, a class regex that fails its own canary, failed source
# enumeration) still exits non-zero the same as the default pass.
# @option --advisory suppress findings, not defects: warn on fuzzy causal-history phrases and exit 0 for those, but still exit 1 on an unterminated fence/generated block/Nix block comment and 2 on a failed source enumeration, a failed candidate scan, a class regex that fails its canary, a structural pass that read fewer sources than were set aside, an unparsable shell source, a shell scan that extracted no comments, a Nix scan that extracted no comments, or a YAML scan that extracted no comments

# Lint: ban "ephemeral references" from the repo's Markdown prose and
# from its shell, Nix and YAML comments. Tracked files describe the CURRENT
# state of the repo, not what they replaced or which plan/PR/date
# introduced them.
#
# Modes:
#   default     — blocking. Scan prose for high-precision banned shapes,
#                 print `file:line: [class] token` to stderr, exit 1 on
#                 any hit.
#   --advisory  — warn-only for hits. Print `[advisory] file:line: phrase`
#                 for fuzzy causal-history phrases and exit 0 for those,
#                 but a could-not-run is a defect, not a finding: it
#                 still exits non-zero the same as the default pass.
#
# The run has four phases, and the first three cost a fixed number of
# processes however large the tree is:
#
#   1. Enumerate — one `git ls-files`.
#   2. Candidate — one `grep --files-with-matches` for the union of the
#      mode's class regexes over every scannable source. A source with
#      no candidate token anywhere in its raw text is not extracted.
#   3. Structural — one `awk` over the Markdown sources the candidate
#      pass set aside and one over the Nix ones, so an unterminated
#      region is still a named could-not-run in a file nothing else
#      reads.
#   4. Extract and scan — the per-language path below, candidates only.
#
# Why the candidate pass cannot hide a violation: every extractor emits,
# for a given source line, either a blank line or a substring of that
# same raw line — Markdown emits the line with exempt regions blanked,
# shell emits `#` prepended to the text `shfmt` reports (and the raw
# line carries that `#`), Nix and YAML emit the line with its indent
# stripped. Blanking only removes text, and removing text cannot create
# a match. The one regex feature that could read differently is the
# left boundary guard: where an extracted match binds `^`, the same
# position in the raw line is preceded by whitespace or by line start,
# because a comment opener requires one and a Markdown line *is* the raw
# line — and whitespace satisfies the guard's negated class. So a match
# in the extracted stream implies a match in the raw file, and skipping
# a file the union does not match is sound. Widening a class regex
# without widening the union it is joined into would break that, which
# is why the union is assembled from these constants rather than written
# out a second time.
#
# What the candidate pass gives up: a shell source with no candidate
# token is never handed to `shfmt`, so a parse failure in it is not
# reported. The verdict is unchanged — a file with no candidate token
# carries no violation to hide — and `shellcheck` and the formatter
# already gate shell parsability. Markdown and Nix keep their
# structural diagnostics through phase 3.
#
# Extraction is per language; matching is shared. A source's extension
# is the whole classifier, and the extracted text reaches one set of
# class regexes whatever it came from.
#
#   Markdown — blank fenced ``` code blocks, blank inline `code` spans,
#     then blank generated BEGIN/END blocks, all in place so reported
#     line numbers stay accurate against the original file, then match
#     the remaining prose. An unterminated fence or generated block
#     exempts every line below it, so it aborts the run (exit 1) rather
#     than scanning what is left.
#   Shell — only comments are prose; everything else is code that
#     legitimately carries banned shapes. Comments are lifted from the
#     `shfmt --to-json` syntax tree, so a token inside a string literal
#     or a heredoc body is out of scope by construction rather than by
#     a regex that has to guess. A source the parser rejects is a
#     could-not-run (exit 2), not a clean read.
#   YAML — only `#` comments that start their own line are read, for
#     the reason the Nix matcher gives. A `#` line inside a `run:` block
#     scalar is read the same as any other: those blocks are embedded
#     shell, and they hold a population no YAML parser can reach, since
#     to one the whole block is a single string. There is no multi-line
#     region to leave open, so this extractor has no could-not-run.
#   Nix — only comments that start their own line are read, `#` line
#     comments and `/* */` block comments alike. No comment-preserving
#     Nix parser is in this toolchain, and without one a trailing `#`
#     or a mid-line `/*` cannot be told from the same characters inside
#     a string, so the matcher gives up the mid-line case to keep the
#     line-start case exact. A `''…''` block is a string to Nix, and the
#     `#` lines in one are comments the scan is meant to read. A block
#     comment that never closes leaves every line below it claimed as
#     comment text, so it aborts the run (exit 1) rather than report
#     against a file it is reading wrong.
#
# Every extractor emits one line per source line, so a hit's line number
# is the original file's. Backtick `code spans` inside a comment are
# blanked before matching, the same exemption inline code already gets
# in Markdown: a comment naming a banned shape as an example is
# documentation, not a reference.
#
# Sources scanned: every Markdown, shell, Nix and YAML path git reports for
# the repo — both committed files and uncommitted, unignored ones — minus
# the file allowlist (`CHANGELOG.md`, `docs/releases.md`,
# `tests/fixtures/**`, `.claude/**`). The first two structurally list PR
# refs + dates in prose; fixtures carry the banned shapes as data;
# `.claude/` holds Claude tooling rather than user-facing prose. The
# reviewable spec lives in docs/development/linting.md.
#
# Env overrides (test-only):
#   EPHEMERAL_REFS_ROOT_OVERRIDE    — alternate REPO_ROOT
#   EPHEMERAL_REFS_SOURCES_OVERRIDE — newline-separated list of source
#     files relative to REPO_ROOT.
#
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set, and a shell, Nix or
# YAML scan that extracted no comments (an operator escape hatch, not
# test-only). It never accepts a class regex that fails its canary.
#
# Exits 0 on clean in either mode; 1 on a blocking match (default mode
# only — --advisory exits 0 on the same finding) or an unterminated
# fence/generated block/Nix block comment (both modes); 2 if the source
# set could not be enumerated, the candidate scan could not read a
# source, a class regex fails its canary, the structural pass read
# fewer sources than the candidate pass set aside for it, a shell
# source could not be parsed, or a scan that parsed shell extracted no
# shell comments, a scan that parsed Nix extracted no Nix comments, or
# a scan that parsed YAML extracted no YAML comments (both modes).

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/log.sh
source "${_lib_dir}/lib/log.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"
# shellcheck source=scripts/lib/ephemeral-refs-scope.sh
source "${_lib_dir}/lib/ephemeral-refs-scope.sh"

REPO_ROOT="${EPHEMERAL_REFS_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
readonly REPO_ROOT

ADVISORY=0
for arg in "$@"; do
  case "${arg}" in
  --advisory)
    ADVISORY=1
    ;;
  *)
    printf 'unknown argument: %s\n' "${arg}" >&2
    exit 2
    ;;
  esac
done
readonly ADVISORY

# @description Assert every class regex matches its own canary, and that
# the mode's union matches every canary the mode covers. A class dropped
# from a union, or a join that lost a branch, exits 2 naming the class.
# Deliberately not gated by LINT_ALLOW_EMPTY_SCAN: an empty tree is a
# situation an operator can vouch for, a degenerate matcher is not.
# @stderr `class regex canary failed: <class>` on the first failure
# @exitcode 2 when a canary does not match
function assert_class_canaries() {
  local class canary regex
  local -a rows=(
    "issue-ref	${CANARY_ISSUE}	${RE_ISSUE}"
    "date	${CANARY_DATE}	${RE_DATE}"
    "planning	${CANARY_PLANNING}	${RE_PLANNING}"
    "review	${CANARY_REVIEW}	${RE_REVIEW}"
    "claude-path	${CANARY_CLAUDE}	${RE_CLAUDE}"
    "causal	${CANARY_CAUSAL}	${RE_CAUSAL}"
  )
  local row union
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r class canary regex <<<"${row}"
    if [[ ! ${canary} =~ ${regex} ]]; then
      printf 'class regex canary failed: %s (own regex)\n' "${class}" >&2
      exit 2
    fi
    if [[ ${class} == 'causal' ]]; then
      union="${UNION_ADVISORY}"
    else
      union="${UNION_BLOCKING}"
    fi
    if [[ ! ${canary} =~ ${union} ]]; then
      printf 'class regex canary failed: %s (mode union)\n' "${class}" >&2
      exit 2
    fi
  done
}

# @description Blank ephemeral-exempt regions in place, preserving line
# count so downstream line numbers match the original file. Blanks
# generated <!-- BEGIN x -->/<!-- END x --> blocks (and their markers),
# fenced ``` code blocks (and their fences), and inline `code` spans.
# Runs as two passes: the first blanks code (fences and inline spans),
# the second blanks generated blocks. Because the second pass only ever
# sees prose, a BEGIN marker a doc quotes inside code is documentation
# rather than a block opener, so it can neither raise a phantom
# unterminated-block error nor blank the prose that follows it.
# An opening fence with no closing fence, or a generated BEGIN with no
# matching END, would otherwise blank every line to EOF, silently hiding
# any violation below it — either unterminated region is a doc defect, so
# fail loud (exit 1) instead. The two diagnostics name their own region
# kind so a caller can tell which marker is dangling.
# @arg $1 file path to the source file
# @arg $2 src_rel source path relative to REPO_ROOT (for the error message)
# @arg $3 stats_dir directory each pass writes its region tallies into:
#   `code` holds `<lines> <fence-lines> <spans>`, `gen` holds
#   `<generated-block-lines>`
# @stdout the file with exempt regions replaced by blank lines
# @stderr `src_rel: unterminated code fence` if a fence is never closed,
#   `src_rel: unterminated generated block` if a BEGIN lacks an END
# @exitcode 0 on clean strip, 1 on either unterminated region
function strip_exempt() {
  local -r file="$1"
  local -r src_rel="$2"
  local -r stats_dir="$3"
  # Each pass tallies the regions it blanked and hands them back through a
  # file: the passes are an awk pipeline, so a counter cannot survive as a
  # shell variable. The tallies feed the run's scope summary, which is the
  # only thing distinguishing a doc the lint read in full from one it
  # mostly skipped as exempt.
  # Pass one: code. Every branch emits exactly one line per input line.
  awk -v src_rel="${src_rel}" -v stats="${stats_dir}/code" '
    {
      line = $0
      # Fenced code blocks (backtick or tilde): blank the fences and
      # everything between them.
      if (line ~ /^[[:space:]]*(```|~~~)/) {
        in_fence = !in_fence
        fenced++
        print ""
        next
      }
      if (in_fence) { fenced++; print ""; next }
      # Inline `code` spans: blank span contents in place. Repeatedly
      # replace the shortest backtick-delimited run with same-width
      # spaces so column-free line content (and the line itself) survive.
      while (match(line, /`[^`]*`/)) {
        spans++
        pad = ""
        for (i = 0; i < RLENGTH; i++) pad = pad " "
        line = substr(line, 1, RSTART - 1) pad substr(line, RSTART + RLENGTH)
      }
      print line
    }
    END {
      printf("%d %d %d\n", NR, fenced, spans) > stats
      if (in_fence) {
        printf "%s: unterminated code fence\n", src_rel > "/dev/stderr"
        exit 1
      }
    }
  ' "$(awk_path "${file}")" |
    # Pass two: generated blocks, over pass one's code-free output.
    awk -v src_rel="${src_rel}" -v stats="${stats_dir}/gen" '
    {
      if ($0 ~ /<!--[[:space:]]*BEGIN[[:space:]]/) { in_gen = 1; gen++; print ""; next }
      if (in_gen) {
        if ($0 ~ /<!--[[:space:]]*END[[:space:]]/) { in_gen = 0 }
        gen++
        print ""
        next
      }
      print
    }
    END {
      printf("%d\n", gen) > stats
      if (in_gen) {
        printf "%s: unterminated generated block\n", src_rel > "/dev/stderr"
        exit 1
      }
    }
  '
}

# @description Print the sources whose raw text carries a token of the
# mode's class union — the only ones an extractor can turn into a
# finding. One `grep` for the whole tree, not one per source: the scan
# it replaces spawned five per file and dominated the run.
# `--files-with-matches` names the operand it matched, so the caller
# maps back by path.
# A source that matches nothing is set aside, never dropped: phase 3
# still reads Markdown and Nix for unterminated regions, and the tally
# reports how many were set aside so a run cannot look like it read what
# it skipped.
# @arg $1 union extended-regex union for the mode
# @arg $2 extra_flag `--ignore-case` for the advisory union, empty otherwise
# @arg $@ (from $3) absolute source paths
# @stdout one matching path per line
# @stderr grep's own diagnostic when a source cannot be read
# @exitcode 0 on a clean pass (with or without matches), 2 when grep
#   could not read an operand
function discover_candidates() {
  local -r union="$1"
  local -r extra_flag="$2"
  shift 2
  # Zero operands would leave grep reading stdin, which never returns.
  [[ $# -eq 0 ]] && return 0

  local -a flags=(--files-with-matches --extended-regexp --binary-files=text)
  [[ -n ${extra_flag} ]] && flags+=("${extra_flag}")

  local rc=0
  grep "${flags[@]}" --regexp="${union}" -- "$@" || rc=$?
  # 0 is "matched", 1 is "nothing matched" — the common, clean case.
  # Anything above that is a read failure, which grep reports even when
  # other operands did match, so it can never be read as "no candidates".
  if [[ ${rc} -ge 2 ]]; then
    printf 'candidate scan failed: grep exited %d\n' "${rc}" >&2
    return 2
  fi
  return 0
}

# @description Read every Markdown source the candidate pass set aside
# and report an unterminated code fence or generated block. Same
# verdicts as `strip_exempt`, which still does this for the sources that
# are scanned; this covers the ones that are not, so a malformed doc
# stays a named defect rather than becoming invisible the moment it
# carries no banned token.
# Fences are recognized before generated blocks and inline code spans
# are blanked before a `BEGIN` is looked for, which is what makes a
# marker quoted inside a fence or a code span documentation rather than
# a block opener — the same ordering `strip_exempt`'s two passes get by
# running one after the other.
# `awk` has no per-file END, so each file's state is judged when the
# next one starts and the last one at END.
# The source list arrives on stdin, one REPO_ROOT-relative path per
# line, and each file is opened with `getline` rather than handed over
# as an `awk` file operand. That keeps the diagnostic naming the source
# the way every other diagnostic here does — relative, never by the
# absolute path an operand would carry — and it sidesteps operand
# assignment parsing entirely rather than defending against it per path.
# Newline-free paths are what makes a line-delimited list safe, and
# `check-path-hygiene.sh` is what makes them newline-free.
# @arg $1 stats path the source count is written to
# @arg $2 root REPO_ROOT, prepended to each relative path to open it
# @stdin one REPO_ROOT-relative source path per line
# @stderr `<src>: unterminated code fence` / `<src>: unterminated generated block`
# @exitcode 0 when every source closes its regions, 1 otherwise
function check_md_structure() {
  local -r stats="$1"
  local -r root="$2"
  awk -v stats="${stats}" -v root="${root}" '
    {
      src = $0
      if (src == "") next
      path = root "/" src
      in_fence = 0
      in_gen = 0
      opened = 0
      while ((rc = (getline line < path)) > 0) {
        opened = 1
        if (line ~ /^[[:space:]]*(```|~~~)/) { in_fence = !in_fence; continue }
        if (in_fence) continue
        while (match(line, /`[^`]*`/)) {
          pad = ""
          for (i = 0; i < RLENGTH; i++) pad = pad " "
          line = substr(line, 1, RSTART - 1) pad substr(line, RSTART + RLENGTH)
        }
        if (line ~ /<!--[[:space:]]*BEGIN[[:space:]]/) { in_gen = 1; continue }
        if (in_gen) {
          if (line ~ /<!--[[:space:]]*END[[:space:]]/) { in_gen = 0 }
          continue
        }
      }
      close(path)
      # A file that could not be opened is not a file that closed its
      # regions. Leaving it out of the tally is what the breadth check
      # above the summary reads as a pass that stopped reading.
      if (rc < 0 && !opened) next
      files++
      if (in_fence) {
        printf "%s: unterminated code fence\n", src > "/dev/stderr"
        bad = 1
      }
      if (in_gen) {
        printf "%s: unterminated generated block\n", src > "/dev/stderr"
        bad = 1
      }
    }
    END {
      printf("%d\n", files) > stats
      if (bad) exit 1
    }
  '
}

# @description Read every Nix source the candidate pass set aside and
# report an unterminated `/* */` block comment, the same verdict
# `extract_nix_comments` reaches for the sources that are scanned. Only
# an opener that starts its own line latches, for the reason the
# extractor gives: a mid-line `/*` cannot be told from the one in a
# quoted glob.
# The source list arrives on stdin for the reason the Markdown pass
# takes it that way.
# @arg $1 stats path the source count is written to
# @arg $2 root REPO_ROOT, prepended to each relative path to open it
# @stdin one REPO_ROOT-relative source path per line
# @stderr `<src>: unterminated Nix block comment`
# @exitcode 0 when every source closes its blocks, 1 otherwise
function check_nix_structure() {
  local -r stats="$1"
  local -r root="$2"
  awk -v stats="${stats}" -v root="${root}" '
    {
      src = $0
      if (src == "") next
      path = root "/" src
      in_block = 0
      opened = 0
      while ((rc = (getline line < path)) > 0) {
        opened = 1
        if (in_block) {
          if (index(line, "*/") > 0) { in_block = 0 }
          continue
        }
        if (line ~ /^[[:space:]]*\/\*/) {
          sub(/^[[:space:]]*\/\*/, "", line)
          if (index(line, "*/") == 0) { in_block = 1 }
        }
      }
      close(path)
      if (rc < 0 && !opened) next
      files++
      if (in_block) {
        printf "%s: unterminated Nix block comment\n", src > "/dev/stderr"
        bad = 1
      }
    }
    END {
      printf("%d\n", files) > stats
      if (bad) exit 1
    }
  '
}

# @description Emit one line per source line, carrying that line's shell
# comment text where a comment sits and a blank line everywhere else, so
# a hit's reported line number matches the original file. Comments come
# out of the `shfmt --to-json` syntax tree rather than a `#` regex: a
# regex cannot tell a comment from a hash inside a string literal, or
# from a Markdown heading inside a heredoc, and this repo's own test
# fixtures carry both. The comment node at line 1, column 1 is the
# shebang and is dropped; every other node is kept, including one whose
# text opens with `!`, because a `#!`-shaped comment below the first
# line is prose like any other. A node that does start line 1 without
# opening at column 1 is an indented comment rather than a shebang, so
# it is read.
# @arg $1 file path to the source file
# @arg $2 src_rel source path relative to REPO_ROOT (for the error message)
# @arg $3 stats_dir directory this pass writes `comments` into as
#   `<comment-count> <line-count>`
# @stdout the line-count-preserving comment stream
# @stderr `src_rel: shfmt could not parse this file as shell` on a parse failure
# @exitcode 0 on success, 1 when the file cannot be parsed
function extract_shell_comments() {
  local -r file="$1"
  local -r src_rel="$2"
  local -r stats_dir="$3"

  local ast
  if ! ast="$(shfmt --to-json <"${file}" 2>/dev/null)"; then
    printf '%s: shfmt could not parse this file as shell\n' "${src_rel}" >&2
    return 1
  fi

  # One run-scoped staging file, truncated per source, rather than a
  # `mktemp` per source: the scan reaches this three times a file and
  # the spawns cost more than the work they stage.
  local -r pairs_file="${WORK_DIR}/pairs"
  # Row zero is a sentinel that keeps this file non-empty for a source
  # carrying no comments at all. `awk`'s two-operand `NR == FNR` split
  # reads an empty first operand as no operand, then mistakes the second
  # operand's lines for the first's and emits nothing — a whole file
  # read as blank while still exiting 0. Source line numbers start at
  # one, so row zero can never collide with a real comment.
  printf '0\t\n' >"${pairs_file}"
  # `<line>\t<text>`, one row per comment node. The hash shfmt strips
  # from `.Text` is put back, because a reference written flush against
  # the hash (`#123 …`) is invisible to the class regexes without it.
  if ! jq --raw-output '
      .. | objects
      | select(has("Text") and has("Hash"))
      | select((.Hash.Line == 1 and .Hash.Col == 1) | not)
      | "\(.Hash.Line)\t#\(.Text)"
    ' <<<"${ast}" >>"${pairs_file}"; then
    printf '%s: comment extraction failed\n' "${src_rel}" >&2
    return 1
  fi

  # Two operands: the comment rows first, the source second. Splitting on
  # the FIRST tab only keeps a tab inside a comment's own text intact.
  # The source's line count is tracked in its own variable rather than
  # read off `FNR` at END, which still holds the sentinel row's count
  # when the source itself is empty.
  local rc=0
  awk -v stats="${stats_dir}/comments" '
    NR == FNR {
      if (match($0, /\t/)) {
        lineno = substr($0, 1, RSTART - 1) + 0
        if (lineno > 0) {
          text[lineno] = substr($0, RSTART + 1)
          count++
        }
      }
      next
    }
    {
      src_lines = FNR
      print (FNR in text ? text[FNR] : "")
    }
    END { printf("%d %d\n", count, src_lines) > stats }
  ' "$(awk_path "${pairs_file}")" "$(awk_path "${file}")" || rc=$?
  return "${rc}"
}

# @description Emit one line per source line, carrying that line's Nix
# comment text where a comment that starts its own line sits and a blank
# line everywhere else, so a hit's reported line number matches the
# original file. Both Nix comment forms are read: a `#` line comment, and
# a `/* … */` block comment across however many lines it spans. Nix has
# no comment-preserving parser in this toolchain, so the matcher is
# deliberately conservative about where a comment may open: a trailing
# `#` cannot be told from a `#` inside a string, and a mid-line `/*`
# cannot be told from the `/*` in a glob such as a quoted `dir/*` path,
# which this repo's Nix holds several of. Requiring the opener to start
# its line keeps both forms exact. Only the opener is anchored — the
# closing `*/` is honored wherever it falls on a line. The `''…''` blocks
# in this repo's Nix carry embedded shell, and their `#` lines are
# genuine comments — reading them is the point, not a side effect.
# An unterminated block comment is a fatal read error, not a quirk: the
# state machine has no way back out, so every line below the opener is
# handed on as comment text and the run reports against code — a stable
# header literal in a Nix string surfaces as a prose date. Fail loud
# instead, the same treatment the Markdown path gives an unterminated
# fence, and for the same reason: a source the extractor is reading
# wrong must not produce a verdict of any kind.
# @arg $1 file path to the source file
# @arg $2 src_rel source path relative to REPO_ROOT (for the error message)
# @arg $3 stats_dir directory this pass writes `comments` into as
#   `<comment-count> <line-count>`
# @stdout the line-count-preserving comment stream
# @stderr `src_rel: unterminated Nix block comment` if a `/*` never closes
# @exitcode 0 on clean read, 1 on an unterminated block comment
function extract_nix_comments() {
  local -r file="$1"
  local -r src_rel="$2"
  local -r stats_dir="$3"
  awk -v src_rel="${src_rel}" -v stats="${stats_dir}/comments" '
    {
      line = $0
      # Inside a block comment every line is comment text until the
      # closing delimiter; whatever follows that delimiter is code.
      if (in_block) {
        close_at = index(line, "*/")
        if (close_at > 0) {
          in_block = 0
          line = substr(line, 1, close_at - 1)
        }
        print line
        count++
        next
      }
      # A block comment opening its own line. The one-line form closes on
      # the same line, so test for the delimiter before latching.
      if (line ~ /^[[:space:]]*\/\*/) {
        sub(/^[[:space:]]*\/\*/, "", line)
        close_at = index(line, "*/")
        if (close_at > 0) {
          line = substr(line, 1, close_at - 1)
        } else {
          in_block = 1
        }
        print line
        count++
        next
      }
      # A `#` line comment. Only the indent is stripped: a reference
      # written flush against the hash (`#123 …`) is invisible to the
      # class regexes once the hash is gone.
      if (line ~ /^[[:space:]]*#/) {
        sub(/^[[:space:]]*/, "", line)
        print line
        count++
        next
      }
      print ""
    }
    END {
      printf("%d %d\n", count, NR) > stats
      if (in_block) {
        printf "%s: unterminated Nix block comment\n", src_rel > "/dev/stderr"
        exit 1
      }
    }
  ' "$(awk_path "${file}")"
}

# @description Emit one line per source line, carrying that line's YAML
# comment text where a comment that starts its own line sits and a blank
# line everywhere else, so a hit's reported line number matches the
# original file. YAML has one comment form and no block form, and the
# opener is required to start its line for the reason the Nix matcher
# requires it: a trailing `#` cannot be told from a `#` inside a quoted
# scalar without a parser, and this repo's workflows carry both
# `${{ }}` expressions and shell fragments full of them.
# A `#` line inside a `run:` block scalar is read the same as any other.
# That is deliberate rather than incidental: those blocks are embedded
# shell, their `#` lines are genuine comments, and they are where a
# third of this repo's YAML comments live — including violations no
# comment-node reader can see, because to a YAML parser the whole block
# is one string. The cost is that a `#` line inside a block scalar that
# is *not* shell would be read as a comment; the tree has no such block
# today, and a banned token quoted in backticks is exempt either way.
# Nothing here can fail: there is no multi-line region to leave open, so
# unlike the Markdown and Nix paths this extractor has no could-not-run.
# @arg $1 file path to the source file
# @arg $2 stats_dir directory this pass writes `comments` into as
#   `<comment-count> <line-count>`
# @stdout the line-count-preserving comment stream
function extract_yaml_comments() {
  local -r file="$1"
  local -r stats_dir="$2"
  awk -v stats="${stats_dir}/comments" '
    {
      line = $0
      # Only the indent is stripped: a reference written flush against
      # the hash (`#123 …`) is invisible to the class regexes once the
      # hash is gone.
      if (line ~ /^[[:space:]]*#/) {
        sub(/^[[:space:]]*/, "", line)
        print line
        count++
        next
      }
      print ""
    }
    END { printf("%d %d\n", count, NR) > stats }
  ' "$(awk_path "${file}")"
}

# @description Blank backtick code spans in place, preserving line count,
# and tally them. A comment that names a banned token as an example — the
# class regexes in this very file, an allowlist entry, a scan-scope note
# — is documentation rather than an ephemeral reference, and a code span
# is how this repo's Markdown already marks that distinction.
# @arg $1 file path to the extracted comment stream
# @arg $2 stats_dir directory this pass writes `spans` into
# @stdout the stream with code spans blanked
function blank_code_spans() {
  local -r file="$1"
  local -r stats_dir="$2"
  awk -v stats="${stats_dir}/spans" '
    {
      line = $0
      while (match(line, /`[^`]*`/)) {
        spans++
        pad = ""
        for (i = 0; i < RLENGTH; i++) pad = pad " "
        line = substr(line, 1, RSTART - 1) pad substr(line, RSTART + RLENGTH)
      }
      print line
    }
    END { printf("%d\n", spans) > stats }
  ' "$(awk_path "${file}")"
}

# @description Scan one stripped source for a blocking class and print
# any hits as `file:line: [class] token`.
# @arg $1 src_rel source path relative to REPO_ROOT (for output)
# @arg $2 stripped path to the stripped source
# @arg $3 class class label for output
# @arg $4 regex extended-regex to match
# @stdout nothing
# @stderr one `file:line: [class] token` per hit
# @exitcode 0 always; caller tallies via the printed count
function scan_class() {
  local -r src_rel="$1"
  local -r stripped="$2"
  local -r class="$3"
  local -r regex="$4"

  # `--binary-files=text`: a source carrying a NUL byte anywhere makes
  # grep report `binary file matches` on stderr and print nothing on
  # stdout, which reads here as a clean file. Force the text path so a
  # stray NUL cannot exempt every line around it.
  local matches
  matches="$(grep --line-number --extended-regexp --only-matching --binary-files=text -- "${regex}" "${stripped}" || true)"
  [[ -z ${matches} ]] && return 0

  local match lineno token
  local -r tmp="${WORK_DIR}/matches"
  printf '%s\n' "${matches}" >"${tmp}"
  while IFS= read -r match; do
    [[ -z ${match} ]] && continue
    lineno="${match%%:*}"
    token="${match#*:}"
    # Trim surrounding whitespace left by boundary captures.
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    printf '%s:%s: [%s] %s\n' "${src_rel}" "${lineno}" "${class}" "${token}" >&2
    blocking_hits=$((blocking_hits + 1))
  done <"${tmp}"
}

# @description Scan one stripped source for advisory causal phrases and
# print any hits as `[advisory] file:line: phrase`.
# @arg $1 src_rel source path relative to REPO_ROOT (for output)
# @arg $2 stripped path to the stripped source
# @stderr one `[advisory] file:line: phrase` per hit
function scan_advisory() {
  local -r src_rel="$1"
  local -r stripped="$2"

  # `--binary-files=text` for the same reason the blocking pass forces
  # it: a NUL byte otherwise turns a whole source into one stderr line
  # that carries no findings.
  local matches
  matches="$(grep --line-number --extended-regexp --only-matching --ignore-case --binary-files=text -- "${RE_CAUSAL}" "${stripped}" || true)"
  [[ -z ${matches} ]] && return 0

  local match lineno phrase
  local -r tmp="${WORK_DIR}/matches"
  printf '%s\n' "${matches}" >"${tmp}"
  while IFS= read -r match; do
    [[ -z ${match} ]] && continue
    lineno="${match%%:*}"
    phrase="${match#*:}"
    printf '[advisory] %s:%s: %s\n' "${src_rel}" "${lineno}" "${phrase}" >&2
  done <"${tmp}"
}

# @description NUL-delimited source producer for `enumerate_into`,
# relative to REPO_ROOT. The invariant covers all Markdown prose and
# every shell and Nix comment in the repo, not one directory, so
# enumeration is git's
# rather than a hand-kept path list. The pathspec is built from
# `EPHEMERAL_REFS_TYPES` rather than written out here, so the set this
# reads and the set the gap generator reports as unread come from one
# record set and cannot overlap. They are not complements: anything the
# allowlist skips sits outside both, whether its type is claimed or not.
# `--cached` covers tracked sources.
# `--others --exclude-standard` adds sources that are not committed yet
# but are not ignored either — exactly the files a commit is about to
# introduce, so a new doc or script is gated by the same run that
# introduces it. Honoring the ignore rules keeps build outputs and
# dependency trees out of the scan. Sorted (NUL-delimited) so
# diagnostics report in a stable order.
# @stdout NUL-delimited source paths, sorted
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function ephemeral_refs_git_sources() {
  local -a pathspec=()
  ephemeral_refs_pathspec_into pathspec
  (cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -z -- "${pathspec[@]}") |
    sort --zero-terminated
}

function main() {
  local -a sources=()
  if [[ -n ${EPHEMERAL_REFS_SOURCES_OVERRIDE:-} ]]; then
    local src
    while IFS= read -r src; do
      [[ -z ${src} ]] && continue
      sources+=("${src}")
    done <<<"${EPHEMERAL_REFS_SOURCES_OVERRIDE}"
  else
    enumerate_into sources 'git ls-files' ephemeral_refs_git_sources
  fi

  # The parser is required only by a source set that actually holds
  # shell, so a Markdown-only run stays runnable on a host without it.
  local src_probe
  for src_probe in "${sources[@]}"; do
    if [[ $(language_of "${src_probe}") == 'sh' ]]; then
      require_tool shfmt
      require_tool jq
      break
    fi
  done

  # A degenerate matcher is not a state an operator can vouch for the
  # way an empty tree is, so this runs ahead of everything and answers
  # to no override.
  assert_class_canaries

  blocking_hits=0
  local md_sources=0 shell_sources=0 nix_sources=0 yaml_sources=0
  local md_parsed=0 shell_parsed=0 nix_parsed=0 yaml_parsed=0
  # Comments are tallied per language, never summed into one counter.
  # The two corpora differ by an order of magnitude, so a shared total
  # stays comfortably positive when one extractor stops matching
  # entirely — the breadth assertion below would then pass on the
  # strength of the other language's comments alone.
  local allowlisted=0 prefiltered=0 lines=0
  local shell_comments=0 nix_comments=0 yaml_comments=0
  local fenced=0 spans=0 gen=0
  local f_lines f_fenced f_spans f_gen f_comments

  WORK_DIR="$(make_temp --directory)"
  local -r stripped="${WORK_DIR}/stripped"
  local -r raw="${WORK_DIR}/raw"

  # One prefix builds every `grep` and `awk` operand, and the structural
  # pass strips the same prefix back off, so a diagnostic names its
  # source relative to REPO_ROOT the way every other diagnostic here
  # does. `awk_path` is what keeps a relative root from being read as a
  # variable assignment.
  local op_prefix
  op_prefix="$(awk_path "${REPO_ROOT}")/"
  readonly op_prefix

  # Classify once. The language is carried alongside the path rather
  # than recomputed later: `language_of` runs in a command substitution,
  # and a second pass over the tree would fork once per source for an
  # answer already known.
  local -a scan_rel=() scan_op=() scan_lang=()
  local src_rel lang
  for src_rel in "${sources[@]}"; do
    [[ -z ${src_rel} ]] && continue
    if is_allowlisted "${src_rel}"; then
      allowlisted=$((allowlisted + 1))
      continue
    fi
    [[ -f "${REPO_ROOT}/${src_rel}" ]] || continue
    lang="$(language_of "${src_rel}")"
    # An extension no extractor claims carries no prose this lint can
    # read, so it is skipped rather than guessed at.
    [[ ${lang} == 'other' ]] && continue
    case "${lang}" in
    md) md_sources=$((md_sources + 1)) ;;
    sh) shell_sources=$((shell_sources + 1)) ;;
    nix) nix_sources=$((nix_sources + 1)) ;;
    yaml) yaml_sources=$((yaml_sources + 1)) ;;
    esac
    scan_rel+=("${src_rel}")
    scan_op+=("${op_prefix}${src_rel}")
    scan_lang+=("${lang}")
  done

  # Candidate pass: one grep for the whole tree.
  local union extra_flag
  if [[ ${ADVISORY} -eq 1 ]]; then
    union="${UNION_ADVISORY}"
    extra_flag='--ignore-case'
  else
    union="${UNION_BLOCKING}"
    extra_flag=''
  fi
  local -r candidates_file="${WORK_DIR}/candidates"
  if ! discover_candidates "${union}" "${extra_flag}" "${scan_op[@]}" \
    >"${candidates_file}"; then
    rm --recursive --force -- "${WORK_DIR}"
    exit 2
  fi
  local -A is_candidate=()
  local op
  while IFS= read -r op; do
    [[ -z ${op} ]] && continue
    is_candidate["${op}"]=1
  done <"${candidates_file}"

  # Structural pass over the Markdown and Nix sources the candidate pass
  # set aside. A malformed region is a could-not-run wherever it sits,
  # and nothing else will read these files.
  local -a md_aside=() nix_aside=()
  local i
  for i in "${!scan_rel[@]}"; do
    [[ -n ${is_candidate["${scan_op[i]}"]:-} ]] && continue
    case "${scan_lang[i]}" in
    md) md_aside+=("${scan_rel[i]}") ;;
    nix) nix_aside+=("${scan_rel[i]}") ;;
    esac
  done
  # The lists go through files rather than arguments: a redirection is
  # not an `awk` operand, so the paths never reach operand assignment
  # parsing at all.
  local -r md_list="${WORK_DIR}/md-aside"
  local -r nix_list="${WORK_DIR}/nix-aside"
  : >"${md_list}"
  : >"${nix_list}"
  [[ ${#md_aside[@]} -gt 0 ]] && printf '%s\n' "${md_aside[@]}" >"${md_list}"
  [[ ${#nix_aside[@]} -gt 0 ]] && printf '%s\n' "${nix_aside[@]}" >"${nix_list}"
  local md_struct=0 nix_struct=0
  if ! check_md_structure "${WORK_DIR}/md-struct" "${REPO_ROOT}" \
    <"${md_list}"; then
    rm --recursive --force -- "${WORK_DIR}"
    exit 1
  fi
  IFS=' ' read -r md_struct <"${WORK_DIR}/md-struct"
  if ! check_nix_structure "${WORK_DIR}/nix-struct" "${REPO_ROOT}" \
    <"${nix_list}"; then
    rm --recursive --force -- "${WORK_DIR}"
    exit 1
  fi
  IFS=' ' read -r nix_struct <"${WORK_DIR}/nix-struct"
  # The structural pass is the only thing that reads a set-aside source,
  # so a pass that has stopped opening files leaves nothing behind to
  # notice. Count what it read against what was set aside for it.
  if [[ ${md_struct} -ne ${#md_aside[@]} ||
    ${nix_struct} -ne ${#nix_aside[@]} ]]; then
    printf 'structural pass read %d of %d markdown and %d of %d nix source(s) set aside\n' \
      "${md_struct}" "${#md_aside[@]}" "${nix_struct}" "${#nix_aside[@]}" >&2
    rm --recursive --force -- "${WORK_DIR}"
    exit 2
  fi

  local src_abs
  for i in "${!scan_rel[@]}"; do
    if [[ -z ${is_candidate["${scan_op[i]}"]:-} ]]; then
      prefiltered=$((prefiltered + 1))
      continue
    fi
    src_rel="${scan_rel[i]}"
    src_abs="${REPO_ROOT}/${src_rel}"

    case "${scan_lang[i]}" in
    md)
      # An unterminated code fence or generated block is a fatal doc
      # defect: fail loud rather than let strip_exempt blank to EOF and
      # hide violations.
      if ! strip_exempt "${src_abs}" "${src_rel}" "${WORK_DIR}" >"${stripped}"; then
        rm --recursive --force -- "${WORK_DIR}"
        exit 1
      fi
      md_parsed=$((md_parsed + 1))
      # The tally files are space-separated; the script-wide IFS is not, so
      # read with a field separator of its own.
      IFS=' ' read -r f_lines f_fenced f_spans <"${WORK_DIR}/code"
      IFS=' ' read -r f_gen <"${WORK_DIR}/gen"
      lines=$((lines + f_lines))
      fenced=$((fenced + f_fenced))
      spans=$((spans + f_spans))
      gen=$((gen + f_gen))
      ;;
    sh)
      # A source the parser rejects is a could-not-run: reporting it as
      # clean would hide every comment in it behind an exit 0.
      if ! extract_shell_comments "${src_abs}" "${src_rel}" "${WORK_DIR}" >"${raw}"; then
        rm --recursive --force -- "${WORK_DIR}"
        exit 2
      fi
      blank_code_spans "${raw}" "${WORK_DIR}" >"${stripped}"
      shell_parsed=$((shell_parsed + 1))
      IFS=' ' read -r f_comments f_lines <"${WORK_DIR}/comments"
      IFS=' ' read -r f_spans <"${WORK_DIR}/spans"
      shell_comments=$((shell_comments + f_comments))
      lines=$((lines + f_lines))
      spans=$((spans + f_spans))
      ;;
    nix)
      # An unterminated block comment leaves the extractor reading code
      # as comment text, so it is a fatal defect on this path exactly as
      # an unterminated fence is on the Markdown one.
      if ! extract_nix_comments "${src_abs}" "${src_rel}" "${WORK_DIR}" >"${raw}"; then
        rm --recursive --force -- "${WORK_DIR}"
        exit 1
      fi
      blank_code_spans "${raw}" "${WORK_DIR}" >"${stripped}"
      nix_parsed=$((nix_parsed + 1))
      IFS=' ' read -r f_comments f_lines <"${WORK_DIR}/comments"
      IFS=' ' read -r f_spans <"${WORK_DIR}/spans"
      nix_comments=$((nix_comments + f_comments))
      lines=$((lines + f_lines))
      spans=$((spans + f_spans))
      ;;
    yaml)
      # No failure path: the matcher holds no multi-line state, so there
      # is no region it can be left reading wrong.
      extract_yaml_comments "${src_abs}" "${WORK_DIR}" >"${raw}"
      blank_code_spans "${raw}" "${WORK_DIR}" >"${stripped}"
      yaml_parsed=$((yaml_parsed + 1))
      IFS=' ' read -r f_comments f_lines <"${WORK_DIR}/comments"
      IFS=' ' read -r f_spans <"${WORK_DIR}/spans"
      yaml_comments=$((yaml_comments + f_comments))
      lines=$((lines + f_lines))
      spans=$((spans + f_spans))
      ;;
    esac

    if [[ ${ADVISORY} -eq 1 ]]; then
      scan_advisory "${src_rel}" "${stripped}"
    else
      scan_class "${src_rel}" "${stripped}" 'issue-ref' "${RE_ISSUE}"
      scan_class "${src_rel}" "${stripped}" 'date' "${RE_DATE}"
      scan_class "${src_rel}" "${stripped}" 'planning' "${RE_PLANNING}"
      scan_class "${src_rel}" "${stripped}" 'review' "${RE_REVIEW}"
      scan_class "${src_rel}" "${stripped}" 'claude-path' "${RE_CLAUDE}"
    fi
  done
  rm --recursive --force -- "${WORK_DIR}"

  # A clean run has nothing to say about findings, which leaves an
  # operator unable to tell prose the lint read from prose it skipped —
  # an allowlisted path, a file that is mostly fenced code, or a source
  # the candidate pass set aside. State the scope instead: what was
  # enumerated, how much of it was parsed, and what was exempted. The
  # per-language source counts are what catches a run that has stopped
  # seeing one language while still exiting 0.
  printf 'ephemeral-refs: scanned %d markdown, %d shell, %d nix, %d yaml source(s); parsed %d candidate(s), pre-filtered %d; %d line(s), %d shell comment(s), %d nix comment(s), %d yaml comment(s); skipped %d allowlisted; exempted %d code-fence line(s), %d inline code span(s), %d generated-block line(s)\n' \
    "${md_sources}" "${shell_sources}" "${nix_sources}" "${yaml_sources}" \
    "$((md_parsed + shell_parsed + nix_parsed + yaml_parsed))" "${prefiltered}" \
    "${lines}" "${shell_comments}" "${nix_comments}" "${yaml_comments}" \
    "${allowlisted}" "${fenced}" \
    "${spans}" "${gen}"

  # A gate that reads no comments has not found a clean tree, it has
  # stopped reading: assert the count rather than infer it from a clean
  # exit, the same rule the enumeration helper applies to file counts.
  # The count is scoped to the sources actually parsed — a language
  # whose every source was set aside has no comments to answer for, and
  # the pre-filtered tally above is what states that. Each language
  # still answers for its own corpus, because the repo's shell comments
  # outnumber its Nix comments better than ten to one and a joint total
  # would stay far from zero with the Nix extractor matching nothing.
  if [[ ${shell_parsed} -gt 0 && ${shell_comments} -eq 0 &&
    -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf 'no comments extracted from %d shell source(s)\n' \
      "${shell_parsed}" >&2
    exit 2
  fi
  if [[ ${nix_parsed} -gt 0 && ${nix_comments} -eq 0 &&
    -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf 'no comments extracted from %d nix source(s)\n' \
      "${nix_parsed}" >&2
    exit 2
  fi
  if [[ ${yaml_parsed} -gt 0 && ${yaml_comments} -eq 0 &&
    -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf 'no comments extracted from %d yaml source(s)\n' \
      "${yaml_parsed}" >&2
    exit 2
  fi

  if [[ ${ADVISORY} -eq 1 ]]; then
    exit 0
  fi
  if [[ ${blocking_hits} -gt 0 ]]; then
    printf '\n%d ephemeral-reference violation(s)\n' "${blocking_hits}" >&2
    exit 1
  fi
  exit 0
}

main "$@"
