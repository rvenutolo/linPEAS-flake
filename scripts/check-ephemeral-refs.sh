#!/usr/bin/env bash
# scripts/check-ephemeral-refs.sh
#
# @description Lint: every Markdown file, shell script and Nix source in
# the repo must carry no ephemeral references — PR/issue refs, prose
# dates, planning/review-pass labels, or literal `.claude/` paths.
# Markdown is read as prose; shell is read as comments only, lifted from
# the `shfmt` syntax tree; Nix is read as the comments that start their
# own line, both `#` line comments and `/* */` block comments.
# Default mode blocks (exit 1); --advisory mode
# suppresses findings, not defects: it warns on fuzzy causal-history
# phrases and exits 0 on those, but a could-not-run (unterminated
# fence/generated block/Nix block comment, unparsable shell, a shell
# scan or a Nix scan that extracted no comments, failed source
# enumeration) still exits non-zero the same as the default pass.
# @option --advisory suppress findings, not defects: warn on fuzzy causal-history phrases and exit 0 for those, but still exit 1 on an unterminated fence/generated block/Nix block comment and 2 on a failed source enumeration, an unparsable shell source, a shell scan that extracted no comments, or a Nix scan that extracted no comments

# Lint: ban "ephemeral references" from the repo's Markdown prose and
# from its shell and Nix comments. Tracked files describe the CURRENT
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
# Sources scanned: every Markdown, shell and Nix path git reports for
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
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set, and a shell or Nix
# scan that extracted no comments (an operator escape hatch, not
# test-only).
#
# Exits 0 on clean in either mode; 1 on a blocking match (default mode
# only — --advisory exits 0 on the same finding) or an unterminated
# fence/generated block/Nix block comment (both modes); 2 if the source
# set could not be enumerated, a shell source could not be parsed, or a
# scan covering shell extracted no shell comments or a scan covering Nix
# extracted no Nix comments (both modes).

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"
# shellcheck source=scripts/lib/log.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/log.sh"

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

# Blocking classes. Boundary-guarded issue ref: a leading boundary that
# is not `-`, `&`, or a word char (so `#1-anchor` anchor targets,
# `&#123;` HTML numeric entities, and `#fff` hex colors do not match)
# followed by `#` and digits, then a trailing boundary that is not `-`
# or a word char (so `#1-anchor` is excluded by its trailing `-`).
readonly RE_ISSUE='(^|[^-&[:alnum:]_])#[0-9]+([^-[:alnum:]_]|$)'
readonly RE_DATE='([0-9]{4}-[0-9]{2}-[0-9]{2}|(January|February|March|April|May|June|July|August|September|October|November|December)[[:space:]]+[0-9]{4}|Q[1-4][[:space:]]+[0-9]{4})'
# Each enumerated shape carries the same left boundary guard as
# RE_ISSUE so it cannot match inside a larger token (e.g. `UTF-8` ->
# `F-8`, `PDF-1.7` -> `F-1`, `ID5:` -> `D5:`). No right guard on shapes
# ending in literal punctuation (`(D3)`, `D5:`, `(L4,`) — that suffix is
# itself the boundary.
readonly RE_PLANNING='(^|[^-&[:alnum:]_])(GAP-[0-9]+|P[0-9]+\.[0-9]+|Wave-P?[0-9]+|Phase[[:space:]]+[0-9]+|AU-P-[0-9]+|SC-POST-[0-9]+|plan[[:space:]]+[0-9]+|F-[0-9]+)'
readonly RE_REVIEW='(^|[^-&[:alnum:]_])(\(D[0-9]+\)|\(L[0-9]+[,)]|Per[[:space:]]+D[0-9]+|D[0-9]+:)'
readonly RE_CLAUDE='\.claude/'

# Advisory class: fuzzy causal-history phrases.
readonly RE_CAUSAL='(prior to|previously|Migration note|was reshaped|Tightened from|swapped|switched (from|to)|legacy .* was deleted|added in #?[0-9]+|post-PR #?[0-9]+)'

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

# @description Language of one source, by extension. Extension is the
# whole classifier: a shell library without a `.sh` suffix, and shell
# embedded in a workflow `run:` block, are out of scope by construction
# rather than by a content sniff that would have to guess.
# @arg $1 src_rel source path relative to REPO_ROOT
# @stdout one of `md`, `sh`, `nix`, `other`
function language_of() {
  case "$1" in
  *.md) printf 'md\n' ;;
  *.sh) printf 'sh\n' ;;
  *.nix) printf 'nix\n' ;;
  *) printf 'other\n' ;;
  esac
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

  local pairs_file
  pairs_file="$(mktemp)"
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
    rm --force -- "${pairs_file}"
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
  rm --force -- "${pairs_file}"
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
  local tmp
  tmp="$(mktemp)"
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
  rm --force -- "${tmp}"
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
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "${matches}" >"${tmp}"
  while IFS= read -r match; do
    [[ -z ${match} ]] && continue
    lineno="${match%%:*}"
    phrase="${match#*:}"
    printf '[advisory] %s:%s: %s\n' "${src_rel}" "${lineno}" "${phrase}" >&2
  done <"${tmp}"
  rm --force -- "${tmp}"
}

# @description NUL-delimited source producer for `enumerate_into`,
# relative to REPO_ROOT. The invariant covers all Markdown prose and
# every shell and Nix comment in the repo, not one directory, so
# enumeration is git's
# rather than a hand-kept path list. `--cached` covers tracked sources.
# `--others --exclude-standard` adds sources that are not committed yet
# but are not ignored either — exactly the files a commit is about to
# introduce, so a new doc or script is gated by the same run that
# introduces it. Honoring the ignore rules keeps build outputs and
# dependency trees out of the scan. Sorted (NUL-delimited) so
# diagnostics report in a stable order.
# @stdout NUL-delimited source paths, sorted
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function ephemeral_refs_git_sources() {
  (cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -z -- '*.md' '*.sh' '*.nix') |
    sort --zero-terminated
}

# @description True when the given source path is on the skip-entirely
# file allowlist (`CHANGELOG.md`, `docs/releases.md`,
# `tests/fixtures/**`, `.claude/**`).
# @arg $1 src_rel source path relative to REPO_ROOT
function is_allowlisted() {
  local -r src_rel="$1"
  case "${src_rel}" in
  # `.claude/` holds Claude tooling rather than user-facing prose, so its
  # workflow-phase and label vocabulary is not an ephemeral reference.
  CHANGELOG.md | docs/releases.md | tests/fixtures/* | .claude/*)
    return 0
    ;;
  esac
  return 1
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

  blocking_hits=0
  local md_sources=0 shell_sources=0 nix_sources=0
  # Comments are tallied per language, never summed into one counter.
  # The two corpora differ by an order of magnitude, so a shared total
  # stays comfortably positive when one extractor stops matching
  # entirely — the breadth assertion below would then pass on the
  # strength of the other language's comments alone.
  local allowlisted=0 lines=0 shell_comments=0 nix_comments=0
  local fenced=0 spans=0 gen=0
  local f_lines f_fenced f_spans f_gen f_comments
  local stats_dir
  stats_dir="$(mktemp -d)"

  local src_rel src_abs stripped lang raw
  for src_rel in "${sources[@]}"; do
    [[ -z ${src_rel} ]] && continue
    if is_allowlisted "${src_rel}"; then
      allowlisted=$((allowlisted + 1))
      continue
    fi
    src_abs="${REPO_ROOT}/${src_rel}"
    [[ -f ${src_abs} ]] || continue
    lang="$(language_of "${src_rel}")"
    # An extension no extractor claims carries no prose this lint can
    # read, so it is skipped rather than guessed at.
    [[ ${lang} == 'other' ]] && continue

    stripped="$(mktemp)"
    case "${lang}" in
    md)
      # An unterminated code fence or generated block is a fatal doc
      # defect: fail loud rather than let strip_exempt blank to EOF and
      # hide violations.
      if ! strip_exempt "${src_abs}" "${src_rel}" "${stats_dir}" >"${stripped}"; then
        rm --force -- "${stripped}"
        rm --recursive --force -- "${stats_dir}"
        exit 1
      fi
      md_sources=$((md_sources + 1))
      # The tally files are space-separated; the script-wide IFS is not, so
      # read with a field separator of its own.
      IFS=' ' read -r f_lines f_fenced f_spans <"${stats_dir}/code"
      IFS=' ' read -r f_gen <"${stats_dir}/gen"
      lines=$((lines + f_lines))
      fenced=$((fenced + f_fenced))
      spans=$((spans + f_spans))
      gen=$((gen + f_gen))
      ;;
    sh)
      # A source the parser rejects is a could-not-run: reporting it as
      # clean would hide every comment in it behind an exit 0.
      raw="$(mktemp)"
      if ! extract_shell_comments "${src_abs}" "${src_rel}" "${stats_dir}" >"${raw}"; then
        rm --force -- "${raw}" "${stripped}"
        rm --recursive --force -- "${stats_dir}"
        exit 2
      fi
      blank_code_spans "${raw}" "${stats_dir}" >"${stripped}"
      rm --force -- "${raw}"
      shell_sources=$((shell_sources + 1))
      IFS=' ' read -r f_comments f_lines <"${stats_dir}/comments"
      IFS=' ' read -r f_spans <"${stats_dir}/spans"
      shell_comments=$((shell_comments + f_comments))
      lines=$((lines + f_lines))
      spans=$((spans + f_spans))
      ;;
    nix)
      # An unterminated block comment leaves the extractor reading code
      # as comment text, so it is a fatal defect on this path exactly as
      # an unterminated fence is on the Markdown one.
      raw="$(mktemp)"
      if ! extract_nix_comments "${src_abs}" "${src_rel}" "${stats_dir}" >"${raw}"; then
        rm --force -- "${raw}" "${stripped}"
        rm --recursive --force -- "${stats_dir}"
        exit 1
      fi
      blank_code_spans "${raw}" "${stats_dir}" >"${stripped}"
      rm --force -- "${raw}"
      nix_sources=$((nix_sources + 1))
      IFS=' ' read -r f_comments f_lines <"${stats_dir}/comments"
      IFS=' ' read -r f_spans <"${stats_dir}/spans"
      nix_comments=$((nix_comments + f_comments))
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

    rm --force -- "${stripped}"
  done
  rm --recursive --force -- "${stats_dir}"

  # A clean run has nothing to say about findings, which leaves an
  # operator unable to tell prose the lint read from prose it skipped —
  # an allowlisted path, or a file that is mostly fenced code. State the
  # scope instead: what was read, what was set aside, and why. The
  # per-language source counts are what catches a run that has stopped
  # seeing one language while still exiting 0.
  printf 'ephemeral-refs: scanned %d markdown, %d shell, %d nix source(s), %d line(s), %d shell comment(s), %d nix comment(s); skipped %d allowlisted; exempted %d code-fence line(s), %d inline code span(s), %d generated-block line(s)\n' \
    "${md_sources}" "${shell_sources}" "${nix_sources}" "${lines}" \
    "${shell_comments}" "${nix_comments}" "${allowlisted}" "${fenced}" \
    "${spans}" "${gen}"

  # A gate that reads no comments has not found a clean tree, it has
  # stopped reading: assert the count rather than infer it from a clean
  # exit, the same rule the enumeration helper applies to file counts.
  # Each language answers for its own corpus, because the repo's shell
  # comments outnumber its Nix comments better than ten to one — a joint
  # total would stay far from zero with the Nix extractor matching
  # nothing at all.
  if [[ ${shell_sources} -gt 0 && ${shell_comments} -eq 0 &&
    -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf 'no comments extracted from %d shell source(s)\n' \
      "${shell_sources}" >&2
    exit 2
  fi
  if [[ ${nix_sources} -gt 0 && ${nix_comments} -eq 0 &&
    -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
    printf 'no comments extracted from %d nix source(s)\n' \
      "${nix_sources}" >&2
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
