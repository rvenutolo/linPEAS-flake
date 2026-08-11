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
#
# Exits 0 on clean, 1 on any failure.

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

if [[ -n ${DOC_ANCHOR_SOURCES_OVERRIDE:-} ]]; then
  mapfile -t SOURCES < <(printf '%s\n' "${DOC_ANCHOR_SOURCES_OVERRIDE}")
else
  mapfile -t SOURCES < <(
    {
      [[ -f ${REPO_ROOT}/.claude/CLAUDE.md ]] && printf '.claude/CLAUDE.md\n'
      [[ -f ${REPO_ROOT}/README.md ]] && printf 'README.md\n'
      (cd "${REPO_ROOT}" && find docs -type f -name '*.md' 2>/dev/null | sort)
    }
  )
fi

failures=0

for src_rel in "${SOURCES[@]}"; do
  [[ -z ${src_rel} ]] && continue
  src_abs="${REPO_ROOT}/${src_rel}"
  [[ -f ${src_abs} ]] || continue
  src_dir="$(dirname -- "${src_abs}")"

  while IFS= read -r match; do
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
      continue
    fi
    local_headings="$(headings_of "${target_abs}")"
    if ! printf '%s\n' "${local_headings}" | grep --fixed-strings --line-regexp --quiet -- "${anchor}"; then
      available="$(printf '%s\n' "${local_headings}" | paste -sd, -)"
      printf '[anchor-miss] %s:%s: #%s not found in %s (available: %s)\n' \
        "${src_rel}" "${lineno}" "${anchor}" \
        "$(realpath --relative-to="${REPO_ROOT}" -- "${target_abs}")" \
        "${available}" >&2
      failures=$((failures + 1))
    fi
  done < <(
    # `--only-matching` emits one line per link (with its line number),
    # so a line carrying several anchor links is checked link-by-link.
    # Without it, the greedy target extraction below would keep only the
    # last `](...)` on the line and skip every earlier link.
    grep --line-number --only-matching --extended-regexp \
      '\[[^]]+\]\([^)]*#[^)]+\)' "${src_abs}" || true
  )
done

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d failure(s)\n' "${failures}" >&2
  exit 1
fi
exit 0
