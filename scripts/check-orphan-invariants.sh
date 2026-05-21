#!/usr/bin/env bash
# scripts/check-orphan-invariants.sh
#
# Lint: assert docs/invariant-index.md and docs/**/*.md stay in
# lockstep.
#   Forward: every `→ [<path>](<path>)` pointer in the index resolves
#            to an existing file under docs/.
#   Reverse: every docs/**/*.md (minus EXEMPT and the index itself)
#            has an index entry.
#
# Entries inside the index use paths RELATIVE TO docs/ (e.g.
# `[security/foo.md](security/foo.md)`).
#
# Env overrides (test-only):
#   INVARIANT_INDEX_OVERRIDE — alternate index path
#   DOCS_ROOT_OVERRIDE       — alternate docs/ root
#
# Exits 0 on clean, 1 on any failure. All failures reported.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly INDEX="${INVARIANT_INDEX_OVERRIDE:-${REPO_ROOT}/docs/invariant-index.md}"
readonly DOCS_ROOT="${DOCS_ROOT_OVERRIDE:-${REPO_ROOT}/docs}"

# docs-relative paths that are intentionally not in the index.
readonly EXEMPT=(
  "dashboard.md"
  "index.md"
  "install/consume-from-flake.md"
  "install/nix.md"
  "invariant-index.md"
  "releases.md"
  "security/threat-model.md"
)

if [[ ! -f ${INDEX} ]]; then
  printf 'invariant index not found: %s\n' "${INDEX}" >&2
  exit 1
fi
if [[ ! -d ${DOCS_ROOT} ]]; then
  printf 'docs root not found: %s\n' "${DOCS_ROOT}" >&2
  exit 1
fi

failures=0

referenced_file="$(mktemp)"
all_docs="$(mktemp)"
trap 'rm -f "${referenced_file}" "${all_docs}"' EXIT

# Extract paths from markdown links of the form [text](path) where
# path looks like a docs-relative .md (no protocol, no leading slash).
# Skip placeholder paths containing `<` or `>`.
{
  grep --line-number --extended-regexp \
    '\[[^]]+\]\([a-z][a-z0-9_/.-]*\.md([#][^)]*)?\)' \
    "${INDEX}" || true
} |
  sed --regexp-extended 's|.*\]\(([a-z][a-z0-9_/.-]*\.md)([#][^)]*)?\).*|\1|' |
  (grep --invert-match --extended-regexp '[<>]' || true) |
  sort --unique >"${referenced_file}"

# Forward check.
while IFS= read -r rel; do
  [[ -z ${rel} ]] && continue
  if [[ ! -f "${DOCS_ROOT}/${rel}" ]]; then
    line="$(grep --line-number --fixed-strings -- "${rel}" "${INDEX}" | head --lines=1 | cut --delimiter=: --fields=1)"
    printf '[orphan-link] %s:%s: docs/%s referenced but file missing\n' \
      "${INDEX}" "${line:-?}" "${rel}" >&2
    failures=$((failures + 1))
  fi
done <"${referenced_file}"

# Reverse check. Walk docs/ as docs-relative paths.
(cd "${DOCS_ROOT}" && find . -type f -name '*.md' | sed 's|^\./||' | sort) >"${all_docs}"

while IFS= read -r rel; do
  [[ -z ${rel} ]] && continue
  exempt=0
  for e in "${EXEMPT[@]}"; do
    if [[ ${rel} == "${e}" ]]; then
      exempt=1
      break
    fi
  done
  [[ ${exempt} -eq 1 ]] && continue
  if ! grep --fixed-strings --quiet --line-regexp -- "${rel}" "${referenced_file}"; then
    printf '[unreferenced-doc] docs/%s exists but no invariant-index entry (add entry to docs/invariant-index.md or extend EXEMPT in scripts/check-orphan-invariants.sh)\n' \
      "${rel}" >&2
    failures=$((failures + 1))
  fi
done <"${all_docs}"

if [[ ${failures} -gt 0 ]]; then
  printf '\n%d failure(s)\n' "${failures}" >&2
  exit 1
fi
exit 0
