#!/usr/bin/env bash
# scripts/check-doc-anchors.sh
#
# @description Lint: every markdown #anchor link pointing at an
# in-tree .md (or same-file fragment) must match a heading slug in
# the target file.

# Lint: every markdown link with a #anchor fragment whose target is
# an in-tree .md (or same-file fragment) must match a heading slug
# in the target.
#
# Sources scanned: docs/invariant-index.md, README.md, docs/**/*.md.
# (.claude/CLAUDE.md is intentionally untracked, so CI cannot scan it.
# The pre-commit hook will scan it locally if present.)
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
# Headings inside fenced code blocks are not headings — a shell comment
# in a ```bash block would otherwise mint a phantom slug that vouches for
# a link GitHub cannot resolve. Fenced blocks are dropped before slugs
# and explicit anchors are collected.
#
# mkdocs-material's toc slugify collapses separator runs, so it can
# disagree with GFM on such a heading. Those headings carry an explicit
# `<a name="...">` anchor, which this lint accepts as a target too.
#
# Env overrides (test-only):
#   DOC_ANCHOR_ROOT_OVERRIDE — alternate REPO_ROOT
#   DOC_ANCHOR_SOURCES_OVERRIDE — newline-separated list of source
#     files relative to REPO_ROOT.
#   LINT_ALLOW_EMPTY_SCAN — set to 1 to accept a run that scanned no
#     source file and checked no link.
#
# Exits 0 on clean, 1 on any failure, 2 when the sources could not be
# enumerated, a source could not be read, or the run covered nothing.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="${DOC_ANCHOR_ROOT_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
readonly REPO_ROOT

function slug() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  s="$(printf '%s' "${s}" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "${s}" | sed --regexp-extended 's/[^a-z0-9 _-]+//g; s/ /-/g')"
  printf '%s\n' "${s}"
}

# @description Echo a file with every fenced code block removed. Fence
# rules follow CommonMark: an opening fence is 3+ backticks or tildes
# indented at most 3 spaces, and only a run of the same character at
# least as long, with nothing after it, closes it. An unterminated fence
# swallows the rest of the file, which is what a renderer does too.
# @arg $1 file
function without_fences() {
  awk '
    {
      if (match($0, /^ ? ? ?(```+|~~~+)/)) {
        marker = substr($0, RSTART, RLENGTH)
        sub(/^ +/, "", marker)
        if (!in_fence) {
          in_fence = 1
          fence_char = substr(marker, 1, 1)
          fence_len = length(marker)
          next
        }
        if (substr(marker, 1, 1) == fence_char &&
            length(marker) >= fence_len &&
            substr($0, RSTART + RLENGTH) ~ /^[ \t]*$/) {
          in_fence = 0
          next
        }
      }
      if (!in_fence) { print }
    }
  ' "$1"
}

function headings_of() {
  local -r f="$1"
  [[ -f ${f} ]] || return 0
  local body
  body="$(without_fences "${f}")"
  # Heading-derived slugs. Strip inline HTML (e.g. `<a name="...">`
  # anchors written by mdformat-toc) before slugging so the computed
  # slug matches the GFM/mkdocs auto-slug, which ignores HTML tags.
  printf '%s\n' "${body}" |
    grep --extended-regexp '^#+[[:space:]]+.+' |
    sed --regexp-extended 's/^#+[[:space:]]+//; s/<[^>]+>//g' |
    while IFS= read -r heading; do
      slug "${heading}"
    done
  # Explicit `<a name="..."></a>` anchors are also valid targets.
  # mdformat-toc writes these next to every in-range heading so its
  # TOC fragments resolve regardless of the slug algorithm in use.
  printf '%s\n' "${body}" |
    grep --extended-regexp --only-matching \
      '<a[[:space:]]+name="[^"]+"' |
    sed --regexp-extended 's/.*name="([^"]+)".*/\1/' || true
}

# @description Count the headings in a file whose slug loses characters to
# the delete step. Those are exactly the slugs where mkdocs-material's
# separator-collapsing slugify can disagree with GFM, so a clean run is
# worth more when it says how much of it rested on them.
# @arg $1 file
function lossy_heading_count() {
  local -r f="$1"
  local body count
  if [[ ! -f ${f} ]]; then
    printf '0\n'
    return 0
  fi
  body="$(without_fences "${f}")"
  # Trailing whitespace is trimmed before slugging, so it is not a deletion.
  count="$(printf '%s\n' "${body}" |
    grep --extended-regexp '^#+[[:space:]]+.+' |
    sed --regexp-extended 's/^#+[[:space:]]+//; s/<[^>]+>//g; s/[[:space:]]+$//' |
    grep --count --extended-regexp '[^A-Za-z0-9 _-]' || true)"
  printf '%s\n' "${count:-0}"
}

declare -a SOURCES=()
if [[ -n ${DOC_ANCHOR_SOURCES_OVERRIDE:-} ]]; then
  mapfile -t SOURCES < <(printf '%s\n' "${DOC_ANCHOR_SOURCES_OVERRIDE}")
else
  # The docs enumeration is captured with its status checked, and the
  # trailing `sort` is applied to the capture rather than to a pipe, so
  # neither `mapfile` nor `sort` stands between a failed `find` and this
  # shell. Both would report their own success while handing the loop
  # below an empty list, and an empty list here produces the same
  # affirmative `ok` line a fully clean run produces — so a docs tree the
  # lint could not read would vouch for every anchor in it.
  sources_out=""
  if [[ -f ${REPO_ROOT}/.claude/CLAUDE.md ]]; then
    sources_out+='.claude/CLAUDE.md'$'\n'
  fi
  if [[ -f ${REPO_ROOT}/README.md ]]; then
    sources_out+='README.md'$'\n'
  fi
  if [[ -d ${REPO_ROOT}/docs ]]; then
    if ! docs_out="$(cd "${REPO_ROOT}" && find docs -type f -name '*.md')"; then
      printf '%s: find failed enumerating %s/docs\n' "${0##*/}" "${REPO_ROOT}" >&2
      exit 2
    fi
    if [[ -n ${docs_out} ]]; then
      sources_out+="$(sort <<<"${docs_out}")"$'\n'
    fi
  fi
  # An empty capture read by `<<<` still yields one empty line, so blank
  # entries are dropped here and the tallies below count real files.
  while IFS= read -r source_rel; do
    [[ -z ${source_rel} ]] && continue
    SOURCES+=("${source_rel}")
  done <<<"${sources_out}"
fi

failures=0

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
      anchor_cache["${target_abs}"]="$(headings_of "${target_abs}")"
      targets_scanned=$((targets_scanned + 1))
      target_anchors=0
      if [[ -n ${anchor_cache[${target_abs}]} ]]; then
        target_anchors="$(printf '%s\n' "${anchor_cache[${target_abs}]}" | wc -l)"
      fi
      anchors_total=$((anchors_total + target_anchors))
      lossy_total=$((lossy_total + $(lossy_heading_count "${target_abs}")))
    fi
    local_headings="${anchor_cache[${target_abs}]}"
    links_checked=$((links_checked + 1))
    if ! printf '%s\n' "${local_headings}" | grep --fixed-strings --line-regexp --quiet -- "${anchor}"; then
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
