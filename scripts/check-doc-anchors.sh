#!/usr/bin/env bash
# scripts/check-doc-anchors.sh
#
# Lint: every markdown link with a #anchor fragment whose target is
# an in-tree .md (or same-file fragment) must match a heading slug
# in the target.
#
# Sources scanned: docs/invariant-index.md, README.md, docs/**/*.md.
# (.claude/CLAUDE.md is intentionally untracked, so CI cannot scan it.
# The pre-commit hook will scan it locally if present.)
#
# Slug algorithm (ASCII; matches GFM and mkdocs-material default):
#   1. Lowercase. 2. Replace non [a-z0-9] with '-'. 3. Collapse '-'.
#   4. Trim '-'.
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
  s="$(printf '%s' "${s}" | sed --regexp-extended 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
  printf '%s\n' "${s}"
}

function headings_of() {
  local -r f="$1"
  [[ -f ${f} ]] || return 0
  # Heading-derived slugs. Strip inline HTML (e.g. `<a name="...">`
  # anchors written by mdformat-toc) before slugging so the computed
  # slug matches the GFM/mkdocs auto-slug, which ignores HTML tags.
  grep --extended-regexp '^#+[[:space:]]+.+' "${f}" |
    sed --regexp-extended 's/^#+[[:space:]]+//; s/<[^>]+>//g' |
    while IFS= read -r heading; do
      slug "${heading}"
    done
  # Explicit `<a name="..."></a>` anchors are also valid targets.
  # mdformat-toc writes these next to every in-range heading so its
  # TOC fragments resolve regardless of the slug algorithm in use.
  grep --extended-regexp --only-matching \
    '<a[[:space:]]+name="[^"]+"' "${f}" 2>/dev/null |
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
    grep --line-number --extended-regexp \
      '\[[^]]+\]\([^)]*#[^)]+\)' "${src_abs}" || true
  )
done

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d failure(s)\n' "${failures}" >&2
  exit 1
fi
exit 0
