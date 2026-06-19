#!/usr/bin/env bash
# scripts/check-ephemeral-refs.sh
#
# @description Lint: tracked Markdown prose must carry no ephemeral
# references — PR/issue refs, prose dates, planning/review-pass labels,
# or literal .claude/ paths. Default mode blocks (exit 1); --advisory
# mode warns on fuzzy causal-history phrases and always exits 0.

# Lint: ban "ephemeral references" from tracked Markdown prose. Tracked
# docs describe the CURRENT state of the repo, not what they replaced or
# which plan/PR/date introduced them.
#
# Modes:
#   default     — blocking. Scan prose for high-precision banned shapes,
#                 print `file:line: [class] token` to stderr, exit 1 on
#                 any hit.
#   --advisory  — warn-only. Print `[advisory] file:line: phrase` for
#                 fuzzy causal-history phrases, always exit 0.
#
# Scanning pipeline (per file): blank generated BEGIN/END blocks, blank
# fenced ``` code blocks, blank inline `code` spans — all in place so
# reported line numbers stay accurate against the original file — then
# match the remaining prose.
#
# Sources scanned: README.md + tracked docs/**/*.md, minus the file
# allowlist (CHANGELOG.md, docs/releases.md, tests/fixtures/**). Those
# structurally list PR refs + dates in prose. .claude/CLAUDE.md is
# intentionally untracked; the reviewable spec lives in
# docs/development/linting.md.
#
# Env overrides (test-only):
#   EPHEMERAL_REFS_ROOT_OVERRIDE    — alternate REPO_ROOT
#   EPHEMERAL_REFS_SOURCES_OVERRIDE — newline-separated list of source
#     files relative to REPO_ROOT.
#
# Exits 0 on clean (and always in --advisory), 1 on any blocking match.

set -Eeuo pipefail
IFS=$'\n\t'

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
# generated <!-- BEGIN x -->/<!-- END x --> blocks (and their fences),
# fenced ``` code blocks (and their fences), and inline `code` spans.
# A generated BEGIN with no matching END would otherwise blank every
# line to EOF, silently hiding any violation below it — an unterminated
# marker is a doc defect, so fail loud (exit 1) instead.
# @arg $1 file path to the source file
# @arg $2 src_rel source path relative to REPO_ROOT (for the error message)
# @stdout the file with exempt regions replaced by blank lines
# @stderr `src_rel: unterminated generated block` if a BEGIN lacks an END
# @exitcode 0 on clean strip, 1 on unterminated generated block
function strip_exempt() {
  local -r file="$1"
  local -r src_rel="$2"
  awk -v src_rel="${src_rel}" '
    {
      line = $0
      # Generated BEGIN/END blocks: blank the markers and everything
      # between them.
      if (line ~ /<!--[[:space:]]*BEGIN[[:space:]]/) { in_gen = 1; print ""; next }
      if (in_gen) {
        if (line ~ /<!--[[:space:]]*END[[:space:]]/) { in_gen = 0 }
        print ""
        next
      }
      # Fenced code blocks (backtick or tilde): blank the fences and
      # everything between them.
      if (line ~ /^[[:space:]]*(```|~~~)/) {
        in_fence = !in_fence
        print ""
        next
      }
      if (in_fence) { print ""; next }
      # Inline `code` spans: blank span contents in place. Repeatedly
      # replace the shortest backtick-delimited run with same-width
      # spaces so column-free line content (and the line itself) survive.
      while (match(line, /`[^`]*`/)) {
        pad = ""
        for (i = 0; i < RLENGTH; i++) pad = pad " "
        line = substr(line, 1, RSTART - 1) pad substr(line, RSTART + RLENGTH)
      }
      print line
    }
    END {
      if (in_gen) {
        printf "%s: unterminated generated block\n", src_rel > "/dev/stderr"
        exit 1
      }
    }
  ' "${file}"
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

function resolve_sources() {
  if [[ -n ${EPHEMERAL_REFS_SOURCES_OVERRIDE:-} ]]; then
    printf '%s\n' "${EPHEMERAL_REFS_SOURCES_OVERRIDE}"
    return 0
  fi
  {
    [[ -f ${REPO_ROOT}/README.md ]] && printf 'README.md\n'
    [[ -d ${REPO_ROOT}/docs ]] &&
      (cd "${REPO_ROOT}" && find docs -type f -name '*.md' 2>/dev/null | sort)
  }
}

# @description True when the given source path is on the skip-entirely
# file allowlist (CHANGELOG.md, docs/releases.md, tests/fixtures/**).
# @arg $1 src_rel source path relative to REPO_ROOT
function is_allowlisted() {
  local -r src_rel="$1"
  case "${src_rel}" in
  CHANGELOG.md | docs/releases.md | tests/fixtures/*)
    return 0
    ;;
  esac
  return 1
}

function main() {
  local sources_tmp
  sources_tmp="$(mktemp)"
  resolve_sources >"${sources_tmp}"
  local -a sources=()
  mapfile -t sources <"${sources_tmp}"
  rm --force -- "${sources_tmp}"

  blocking_hits=0

  local src_rel src_abs stripped
  for src_rel in "${sources[@]}"; do
    [[ -z ${src_rel} ]] && continue
    is_allowlisted "${src_rel}" && continue
    src_abs="${REPO_ROOT}/${src_rel}"
    [[ -f ${src_abs} ]] || continue

    stripped="$(mktemp)"
    # An unterminated generated block is a fatal doc defect: fail loud
    # rather than let strip_exempt blank to EOF and hide violations.
    if ! strip_exempt "${src_abs}" "${src_rel}" >"${stripped}"; then
      rm --force -- "${stripped}"
      exit 1
    fi

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
