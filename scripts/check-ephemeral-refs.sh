#!/usr/bin/env bash
# scripts/check-ephemeral-refs.sh
#
# @description Lint: every Markdown file in the repo must carry no
# ephemeral references — PR/issue refs, prose dates, planning/review-pass
# labels, or literal `.claude/` paths. Default mode blocks (exit 1);
# --advisory mode suppresses findings, not defects: it warns on fuzzy
# causal-history phrases and exits 0 on those, but a could-not-run
# (unterminated fence/block, failed source enumeration) still exits
# non-zero the same as the default pass.
# @option --advisory suppress findings, not defects: warn on fuzzy causal-history phrases and exit 0 for those, but still exit 1 on an unterminated fence/generated block and 2 on a failed source enumeration

# Lint: ban "ephemeral references" from the repo's Markdown prose.
# Tracked docs describe the CURRENT state of the repo, not what they
# replaced or which plan/PR/date introduced them.
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
# Scanning pipeline (per file): blank fenced ``` code blocks, blank
# inline `code` spans, then blank generated BEGIN/END blocks — all in
# place so reported line numbers stay accurate against the original
# file — then match the remaining prose. An unterminated fence or
# generated block exempts every line below it, so it aborts the run
# (exit 1) rather than scanning what is left.
#
# Sources scanned: every Markdown path git reports for the repo — both
# committed files and uncommitted, unignored ones — minus the file
# allowlist (`CHANGELOG.md`, `docs/releases.md`, `tests/fixtures/**`,
# `.claude/**`). The first two structurally list PR refs + dates in
# prose; fixtures carry the banned shapes as data; `.claude/` holds
# Claude tooling rather than user-facing prose. The reviewable spec
# lives in docs/development/linting.md.
#
# Env overrides (test-only):
#   EPHEMERAL_REFS_ROOT_OVERRIDE    — alternate REPO_ROOT
#   EPHEMERAL_REFS_SOURCES_OVERRIDE — newline-separated list of source
#     files relative to REPO_ROOT.
#
# LINT_ALLOW_EMPTY_SCAN=1 accepts an empty scan set (an operator escape
# hatch, not test-only).
#
# Exits 0 on clean in either mode; 1 on a blocking match (default mode
# only — --advisory exits 0 on the same finding) or an unterminated
# fence/generated block (both modes); 2 if the Markdown source set could
# not be enumerated (both modes).

set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck source=scripts/lib/enumerate.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/awk-path.sh"

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

  local matches
  matches="$(grep --line-number --extended-regexp --only-matching -- "${regex}" "${stripped}" || true)"
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

  local matches
  matches="$(grep --line-number --extended-regexp --only-matching --ignore-case -- "${RE_CAUSAL}" "${stripped}" || true)"
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

# @description NUL-delimited Markdown source producer for
# `enumerate_into`, relative to REPO_ROOT. The invariant covers all
# Markdown prose in the repo, not one directory, so enumeration is git's
# rather than a hand-kept path list. `--cached` covers tracked Markdown.
# `--others --exclude-standard` adds Markdown that is not committed yet
# but is not ignored either — exactly the files a commit is about to
# introduce, so a new doc is gated by the same run that introduces it.
# Honoring the ignore rules keeps build outputs and dependency trees out
# of the scan. Sorted (NUL-delimited) so diagnostics report in a stable
# order.
# @stdout NUL-delimited source paths, sorted
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function ephemeral_refs_git_sources() {
  (cd "${REPO_ROOT}" && git ls-files --cached --others --exclude-standard -z -- '*.md') |
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

  blocking_hits=0
  local scanned=0 allowlisted=0 lines=0 fenced=0 spans=0 gen=0
  local f_lines f_fenced f_spans f_gen
  local stats_dir
  stats_dir="$(mktemp -d)"

  local src_rel src_abs stripped
  for src_rel in "${sources[@]}"; do
    [[ -z ${src_rel} ]] && continue
    if is_allowlisted "${src_rel}"; then
      allowlisted=$((allowlisted + 1))
      continue
    fi
    src_abs="${REPO_ROOT}/${src_rel}"
    [[ -f ${src_abs} ]] || continue

    stripped="$(mktemp)"
    # An unterminated code fence or generated block is a fatal doc
    # defect: fail loud rather than let strip_exempt blank to EOF and
    # hide violations.
    if ! strip_exempt "${src_abs}" "${src_rel}" "${stats_dir}" >"${stripped}"; then
      rm --force -- "${stripped}"
      rm --recursive --force -- "${stats_dir}"
      exit 1
    fi
    scanned=$((scanned + 1))
    # The tally files are space-separated; the script-wide IFS is not, so
    # read with a field separator of its own.
    IFS=' ' read -r f_lines f_fenced f_spans <"${stats_dir}/code"
    IFS=' ' read -r f_gen <"${stats_dir}/gen"
    lines=$((lines + f_lines))
    fenced=$((fenced + f_fenced))
    spans=$((spans + f_spans))
    gen=$((gen + f_gen))

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
  # scope instead: what was read, what was set aside, and why.
  printf 'ephemeral-refs: scanned %d source(s), %d line(s); skipped %d allowlisted; exempted %d code-fence line(s), %d inline code span(s), %d generated-block line(s)\n' \
    "${scanned}" "${lines}" "${allowlisted}" "${fenced}" "${spans}" "${gen}"

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
