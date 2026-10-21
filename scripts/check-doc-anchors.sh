#!/usr/bin/env bash
# scripts/check-doc-anchors.sh
#
# @description Lint: every markdown #anchor link pointing at an
# in-tree .md (or same-file fragment) must match a heading slug or an
# explicit `<a name>` anchor in the target file; an anchor link whose
# target `.md` is missing, and a non-ASCII heading with no explicit
# anchor in a scanned source, are reported too.

# Sources scanned: docs/invariant-index.md, README.md, docs/**/*.md.
# (`.claude/CLAUDE.md` is intentionally untracked, so CI cannot scan it.
# The pre-commit hook will scan it locally if present.)
#
# The delete step (step 2 below) runs under a C locale, so a non-ASCII byte
# is always deleted whatever the caller's locale.
#
# Slug algorithm — GFM (github-slugger), ASCII scope:
#   1. Trim surrounding whitespace, then lowercase.
#   2. PRESERVE letters, digits, '_' and '-'. DELETE every other
#      character outright — apostrophes, periods, parentheses, '+', '&',
#      backticks and non-ASCII punctuation such as em dashes and arrows
#      leave nothing behind, so "the image's" slugs to "the-images".
#   3. Replace each remaining space with '-'. Runs are NOT collapsed, so
#      "release + tag" slugs to "release--tag".
# Deleting rather than substituting is what makes step 3 safe: trailing
# punctuation cannot produce a trailing '-', so no trimming is needed.
#
# A heading whose text holds a non-ASCII letter, mark or digit and that
# carries no explicit `<a name="...">` anchor is a `[non-ascii-heading]`
# finding: GitHub keeps the character in the slug and mkdocs folds it to
# ASCII, so no link resolves on both. An anchored one answers only to its
# explicit anchor; no slug is generated for it. Finding such headings needs grep
# --perl-regexp to read code points; a startup probe exits 2 when it
# cannot.
#
# Headings inside fenced code blocks are not headings — a shell comment
# in a ```bash block would otherwise mint a phantom slug that vouches for
# a link GitHub cannot resolve. Fenced blocks are dropped before slugs
# and explicit anchors are collected.
#
# mkdocs-material's toc slugify collapses separator runs, so it can
# disagree with GFM on a heading whose deleted characters leave a
# separator run (`release + tag`). Those headings carry an explicit
# `<a name="...">` anchor, which this lint accepts as a target too.
#
# Env overrides (test-only):
#   DOC_ANCHOR_ROOT_OVERRIDE — alternate REPO_ROOT
#   DOC_ANCHOR_SOURCES_OVERRIDE — newline-separated list of source
#     files relative to REPO_ROOT.
#   LINT_ALLOW_EMPTY_SCAN — set to 1 to accept a run that scanned no
#     source file and checked no link.
#
# Exits 0 on clean, 1 on any failure. Exits 2 when the check cannot run:
# the sources could not be enumerated; grep --perl-regexp under C.UTF-8
# cannot read UTF-8 (startup probe); a source or link target cannot be
# read, holds a NUL byte, is not valid UTF-8, or its headings cannot be
# read; or the run covered nothing.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/enumerate.sh
source "${_lib_dir}/lib/enumerate.sh"
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/repo.sh
source "${_lib_dir}/lib/repo.sh"

REPO_ROOT="${DOC_ANCHOR_ROOT_OVERRIDE:-$(repo_toplevel)}"
readonly REPO_ROOT

function slug() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
  # The pin keeps the delete step independent of the caller's locale
  # whatever the heading filter in headings_of admits.
  s="$(printf '%s' "${s}" | LC_ALL=C sed --regexp-extended 's/[^a-z0-9 _-]+//g; s/ /-/g')"
  printf '%s\n' "${s}"
}

# @description Echo a file with every fenced code block removed. Fence
# rules follow CommonMark: an opening fence is 3+ backticks or tildes
# indented at most 3 spaces, and only a run of the same character at
# least as long, with nothing after it, closes it. An unterminated fence
# swallows the rest of the file, which is what a renderer does too.
# @arg $1 file
# @arg $2 blank: 1 prints an empty line for each dropped line, so line
# numbers of the kept lines survive
function without_fences() {
  awk -v blank="${2:-0}" '
    {
      if (match($0, /^ ? ? ?(```+|~~~+)/)) {
        marker = substr($0, RSTART, RLENGTH)
        sub(/^ +/, "", marker)
        if (!in_fence) {
          in_fence = 1
          fence_char = substr(marker, 1, 1)
          fence_len = length(marker)
          if (blank) print ""
          next
        }
        if (substr(marker, 1, 1) == fence_char &&
            length(marker) >= fence_len &&
            substr($0, RSTART + RLENGTH) ~ /^[ \t]*$/) {
          in_fence = 0
          if (blank) print ""
          next
        }
      }
      if (!in_fence) { print } else if (blank) { print "" }
    }
  ' "$(awk_path "$1")"
}

# @description Emit every anchor a file answers to: the generated slug of
# each heading that has one, then each explicit `<a name="...">` anchor.
# @arg $1 file
# @exitcode 2 the file could not be read
function headings_of() {
  local -r f="$1"
  [[ -f ${f} ]] || return 0
  local body
  body="$(without_fences "${f}")" || return 2
  # Heading-derived slugs. Strip inline HTML (e.g. `<a name="...">`
  # anchors written by mdformat-toc) before slugging so the computed
  # slug matches the GFM/mkdocs auto-slug, which ignores HTML tags.
  # A heading holding a non-ASCII letter, mark or digit has no generated
  # slug: GitHub keeps the character and mkdocs folds it, and the slug
  # sed deletes it, so the result names the heading on neither renderer.
  # Its explicit anchor, collected below, is its only target.
  local headings heading rc
  headings="$(printf '%s\n' "${body}" |
    grep --extended-regexp '^#+[[:space:]]+.+' |
    sed --regexp-extended 's/^#+[[:space:]]+//; s/<[^>]+>//g')" || true
  while IFS= read -r heading; do
    [[ -z ${heading} ]] && continue
    rc=0
    LC_ALL=C.UTF-8 grep --quiet --perl-regexp \
      '[\p{L}\p{M}\p{N}](?<=[^\x00-\x7F])' <<<"${heading}" || rc=$?
    ((rc > 1)) && return 2
    ((rc == 0)) && continue
    slug "${heading}"
  done <<<"${headings}"
  # Explicit `<a name="..."></a>` anchors are also valid targets.
  # mdformat-toc writes these next to every in-range heading so its
  # TOC fragments resolve regardless of the slug algorithm in use.
  printf '%s\n' "${body}" |
    grep --extended-regexp --only-matching \
      '<a[[:space:]]+name="[^"]+"' |
    sed --regexp-extended 's/.*name="([^"]+)".*/\1/' || true
}

# @description Count the headings in a file whose text holds a character
# the slug delete step removes, anchored non-ASCII headings included
# although they have no generated slug. Those are the headings where
# mkdocs-material's separator-collapsing slugify can disagree with GFM,
# so a clean run is worth more when it says how much of it rested on them.
# @arg $1 file
# @exitcode 2 the file could not be read
function lossy_heading_count() {
  local -r f="$1"
  local body count
  if [[ ! -f ${f} ]]; then
    printf '0\n'
    return 0
  fi
  body="$(without_fences "${f}")" || return 2
  # Trailing whitespace is trimmed before slugging, so it is not a deletion.
  count="$(printf '%s\n' "${body}" |
    grep --extended-regexp '^#+[[:space:]]+.+' |
    sed --regexp-extended 's/^#+[[:space:]]+//; s/<[^>]+>//g; s/[[:space:]]+$//' |
    # The count and the slug sed read one class under one locale.
    LC_ALL=C grep --count --extended-regexp '[^A-Za-z0-9 _-]' || true)"
  printf '%s\n' "${count:-0}"
}

# @description Emit `<line>\t<text>` for each heading in a file whose text
# holds a non-ASCII letter, mark or digit and whose line carries no
# explicit `<a name="...">` anchor. GitHub keeps such a character in the
# slug and mkdocs folds it to ASCII, so no link resolves on both and only
# an explicit anchor gives the heading one name. Non-ASCII punctuation is
# deleted by both and is not reported.
# @arg $1 file
# @exitcode 0 records or none
# @exitcode 2 grep could not read the text
function non_ascii_headings() {
  local -r f="$1"
  local hits text rc=0
  # PCRE reads code points only in a UTF-8 locale; the startup probe
  # proves this grep does.
  # The text is read into a variable first: in a pipeline an awk read
  # failure leaves grep an empty input, and "no match" would hide it.
  # The text passes through a bash variable, which drops a NUL byte before
  # grep sees it; --binary-files=text is a second guard against a "binary
  # file matches" notice reading as a pass.
  text="$(without_fences "${f}" 1)" || return 2
  hits="$(printf '%s\n' "${text}" |
    LC_ALL=C.UTF-8 grep --line-number --perl-regexp --binary-files=text \
      '^#+[[:space:]]+(?!.*<a[[:space:]]+name=")(?=.*[\p{L}\p{M}\p{N}](?<=[^\x00-\x7F]))')" || rc=$?
  ((rc > 1)) && return 2
  [[ -n ${hits} ]] || return 0
  printf '%s\n' "${hits}" |
    sed --regexp-extended 's/^([0-9]+):#+[[:space:]]+/\1\t/; s/[[:space:]]+$//'
}

# @description Emit every docs/**/*.md path, NUL-delimited and sorted,
# relative to REPO_ROOT. The `cd` is what makes the emitted paths
# repo-relative (`docs/...` rather than an absolute path), so it is kept
# inside this same-file wrapper rather than folded into the `find`
# invocation directly: a function invoked as a command is not a process
# substitution feeding a redirection, which is the shape
# check-no-opaque-procsub.sh bans.
# shellcheck disable=SC2329 # invoked indirectly, by name, via enumerate_into
function doc_anchor_docs_scan() {
  (cd "${REPO_ROOT}" && find docs -type f -name '*.md' -print0) |
    sort --zero-terminated
}

declare -a SOURCES=()
if [[ -n ${DOC_ANCHOR_SOURCES_OVERRIDE:-} ]]; then
  mapfile -t SOURCES <<<"${DOC_ANCHOR_SOURCES_OVERRIDE}"
else
  # SOURCES is built by appending arrays, never by joining paths into a
  # newline-delimited string and re-splitting it: a docs/ path carrying an
  # embedded newline survives `enumerate_into` as one array element, and a
  # join-then-`read`-split round trip would fracture it right back into two
  # nonexistent paths — the exact bug this conversion exists to close.
  if [[ -f ${REPO_ROOT}/.claude/CLAUDE.md ]]; then
    SOURCES+=('.claude/CLAUDE.md')
  fi
  if [[ -f ${REPO_ROOT}/README.md ]]; then
    SOURCES+=('README.md')
  fi
  if [[ -d ${REPO_ROOT}/docs ]]; then
    # An empty docs/ tree here would produce the same affirmative `ok` line
    # a fully clean run produces — so a docs tree the lint could not read
    # would vouch for every anchor in it. LINT_ALLOW_EMPTY_SCAN is forced
    # for this call alone because a repo may legitimately carry README.md
    # or `.claude/CLAUDE.md` as its only source and no docs/ tree at all —
    # the combined-SOURCES breadth check below (unchanged) is what still
    # catches every root coming back empty.
    docs_paths=()
    LINT_ALLOW_EMPTY_SCAN=1 enumerate_into docs_paths 'find docs' doc_anchor_docs_scan
    SOURCES+=(${docs_paths+"${docs_paths[@]}"})
  fi
fi

# @description Exit 2 when a file holds a NUL byte, is not valid UTF-8, or
# cannot be read. grep calls such text binary and prints a notice in place
# of its matches, and a bash variable drops a NUL, so the reads below would
# check such a file only in part. `.` matches a NUL under
# --binary-files=text, so the encoding check alone does not find one.
# @arg $1 file  @arg $2 name to report
function refuse_binary() {
  local rc=0
  LC_ALL=C grep --quiet --binary-files=text --perl-regexp '\x00' -- "$1" || rc=$?
  if ((rc == 0)); then
    printf '%s: refusing %s: it holds a NUL byte\n' "${0##*/}" "$2" >&2
    exit 2
  elif ((rc > 1)); then
    printf '%s: could not read %s to check it for a NUL byte\n' "${0##*/}" "$2" >&2
    exit 2
  fi
  rc=0
  LC_ALL=C.UTF-8 grep --quiet --binary-files=text --line-regexp --invert-match '.*' -- "$1" || rc=$?
  if ((rc == 0)); then
    printf '%s: refusing %s: it is not valid UTF-8\n' "${0##*/}" "$2" >&2
    exit 2
  elif ((rc > 1)); then
    printf '%s: could not read %s to check its encoding\n' "${0##*/}" "$2" >&2
    exit 2
  fi
}

failures=0

# The non-ASCII heading check rests on grep reading code points under
# --perl-regexp. A grep that cannot would match nothing and pass every
# heading, so the run refuses instead.
if [[ "$(printf 'é\n' | LC_ALL=C.UTF-8 grep --count --perl-regexp '^\p{L}$' 2>/dev/null || true)" != 1 ]]; then
  printf '%s: grep --perl-regexp under C.UTF-8 does not read é as a letter, so headings holding a non-ASCII letter cannot be found\n' \
    "${0##*/}" >&2
  exit 2
fi

# Scope tallies for the summary line, plus a per-target cache so a target
# linked many times is slugged once.
declare -A anchor_cache=()
sources_scanned=0
links_checked=0
targets_scanned=0
anchors_total=0
lossy_total=0

for src_rel in "${SOURCES[@]}"; do
  [[ -z ${src_rel} ]] && continue
  src_abs="${REPO_ROOT}/${src_rel}"
  [[ -f ${src_abs} ]] || continue
  sources_scanned=$((sources_scanned + 1))
  src_dir="$(dirname -- "${src_abs}")"

  # `--only-matching` emits one line per link (with its line number), so a
  # line carrying several anchor links is checked link-by-link. Without it,
  # the greedy target extraction below would keep only the last `](...)` on
  # the line and skip every earlier link.
  #
  # grep separates "no links in this file" (1) from "could not read this
  # file" (2), and only the first is data. Collapsing them credits an
  # unreadable file with having no anchor links while still counting it in
  # sources_scanned, so neither the verdict nor the tally moves.
  links_rc=0
  links_out="$(grep --line-number --only-matching --extended-regexp \
    '\[[^]]+\]\([^)]*#[^)]+\)' -- "${src_abs}")" || links_rc=$?
  if ((links_rc > 1)); then
    printf '%s: grep failed reading %s for anchor links\n' \
      "${0##*/}" "${src_rel}" >&2
    exit 2
  fi
  # A NUL-bearing or non-UTF-8 source reads as matching with no links
  # printed, so it is refused here, once grep has shown the file can be
  # read.
  refuse_binary "${src_abs}" "${src_rel}"

  heading_rc=0
  heading_out="$(non_ascii_headings "${src_abs}")" || heading_rc=$?
  if ((heading_rc != 0)); then
    printf '%s: could not read %s for headings\n' "${0##*/}" "${src_rel}" >&2
    exit 2
  fi
  while IFS=$'\t' read -r h_line h_text; do
    [[ -z ${h_line} ]] && continue
    printf '[non-ascii-heading] %s:%s: heading "%s" holds a non-ASCII letter, mark or digit; add an explicit <a name="..."> anchor (GitHub and mkdocs slug it differently)\n' \
      "${src_rel}" "${h_line}" "${h_text}" >&2
    failures=$((failures + 1))
  done <<<"${heading_out}"

  while IFS= read -r match; do
    [[ -z ${match} ]] && continue
    lineno="${match%%:*}"
    rest="${match#*:}"
    target="$(printf '%s' "${rest}" |
      sed --regexp-extended 's/.*\]\(([^)]+)\).*/\1/')"
    case "${target}" in
    http://* | https://* | mailto:*) continue ;;
    esac
    [[ ${target} == *"#"* ]] || continue
    path="${target%%#*}"
    anchor="${target#*#}"
    [[ -z ${anchor} ]] && continue
    if [[ -n ${path} ]]; then
      case "${path}" in
      *.md) ;;
      *) continue ;;
      esac
      target_abs="$(realpath --canonicalize-missing -- "${src_dir}/${path}")"
    else
      target_abs="${src_abs}"
    fi
    if [[ ! -f ${target_abs} ]]; then
      # A link whose target `.md` is not in the tree resolves to nothing
      # when the doc renders, and it is the anchor check that is closest to
      # noticing: it has already resolved the path. Skipping it left the
      # link neither validated nor counted, so a rename that strands a link
      # moved neither the verdict nor the tally, and the skip is per-link —
      # invisible even in a run that fails over some other link.
      printf '[stranded-link] %s:%s: %s links to %s, which does not exist\n' \
        "${src_rel}" "${lineno}" "${target}" \
        "$(realpath --relative-to="${REPO_ROOT}" --canonicalize-missing -- "${target_abs}")" >&2
      failures=$((failures + 1))
      continue
    fi
    if [[ -z ${anchor_cache[${target_abs}]+set} ]]; then
      target_rel="$(realpath --relative-to="${REPO_ROOT}" -- "${target_abs}")"
      refuse_binary "${target_abs}" "${target_rel}"
      target_headings="$(headings_of "${target_abs}")" || {
        printf '%s: could not read %s for headings\n' "${0##*/}" "${target_rel}" >&2
        exit 2
      }
      anchor_cache["${target_abs}"]="${target_headings}"
      targets_scanned=$((targets_scanned + 1))
      target_anchors=0
      if [[ -n ${anchor_cache[${target_abs}]} ]]; then
        target_anchors="$(printf '%s\n' "${anchor_cache[${target_abs}]}" | wc -l)"
      fi
      anchors_total=$((anchors_total + target_anchors))
      target_lossy="$(lossy_heading_count "${target_abs}")" || {
        printf '%s: could not read %s for its lossy-heading count\n' "${0##*/}" "${target_rel}" >&2
        exit 2
      }
      lossy_total=$((lossy_total + target_lossy))
    fi
    local_headings="${anchor_cache[${target_abs}]}"
    links_checked=$((links_checked + 1))
    if ! grep --fixed-strings --line-regexp --quiet -- "${anchor}" <<<"${local_headings}"; then
      available="$(printf '%s\n' "${local_headings}" | paste -sd, -)"
      printf '[anchor-miss] %s:%s: #%s not found in %s (available: %s)\n' \
        "${src_rel}" "${lineno}" "${anchor}" \
        "$(realpath --relative-to="${REPO_ROOT}" -- "${target_abs}")" \
        "${available}" >&2
      failures=$((failures + 1))
    fi
  done <<<"${links_out}"
done

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d failure(s)\n' "${failures}" >&2
  exit 1
fi

# The `ok` line below is the same line whether the run resolved every anchor
# in the tree or resolved none because it read nothing, so the tallies it
# reports are also the floor it has to clear. Each floor names the tally that
# came back zero, because the two say different things about what went wrong:
# no source file means the enumeration never reached the docs, while sources
# with no link between them means the link extraction did.
if [[ -z ${LINT_ALLOW_EMPTY_SCAN:-} ]]; then
  if ((sources_scanned == 0)); then
    printf '%s: scanned 0 source file(s) under %s — an unread tree reports the same ok line a clean one does; set LINT_ALLOW_EMPTY_SCAN=1 if this root is deliberately empty\n' \
      "${0##*/}" "${REPO_ROOT}" >&2
    exit 2
  fi
  if ((links_checked == 0)); then
    printf '%s: checked 0 anchor link(s) across %d source file(s) — an unread tree reports the same ok line a clean one does; set LINT_ALLOW_EMPTY_SCAN=1 if these sources deliberately carry no anchor link\n' \
      "${0##*/}" "${sources_scanned}" >&2
    exit 2
  fi
fi

printf 'check-doc-anchors: ok — %d anchor link(s) in %d source file(s) resolved against %d anchor(s) in %d target file(s); %d heading(s) required character deletion\n' \
  "${links_checked}" "${sources_scanned}" "${anchors_total}" \
  "${targets_scanned}" "${lossy_total}"
exit 0
