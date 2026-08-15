#!/usr/bin/env bash
# scripts/check-orphan-invariants.sh
#
# @description Lint: docs/invariant-index.md and docs/**/*.md stay
# in lockstep — every index pointer resolves to a real file, and
# every non-EXEMPT docs file has an index entry.

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
# Exits 2 when the check cannot run at all — the index or the docs root
# is absent, so neither half of the lockstep can be evaluated. A missing
# input must not borrow the drift code: that reads as a substantive
# docs/index divergence and sends a maintainer after content nobody
# changed.

set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly INDEX="${INVARIANT_INDEX_OVERRIDE:-${REPO_ROOT}/docs/invariant-index.md}"
readonly DOCS_ROOT="${DOCS_ROOT_OVERRIDE:-${REPO_ROOT}/docs}"

# docs-relative paths that are intentionally not in the index.
readonly EXEMPT=(
  "architecture/ci-dag.md"
  "dashboard.md"
  "index.md"
  "install/consume-from-flake.md"
  "install/nix.md"
  "invariant-index.md"
  "reference/just-recipes.md"
  "reference/scripts.md"
  "reference/treefmt-config.md"
  "releases.md"
  "security/enforcement-matrix.md"
  "security/threat-model.md"
)

if [[ ! -f ${INDEX} ]]; then
  printf 'invariant index not found: %s\n' "${INDEX}" >&2
  exit 2
fi
if [[ ! -d ${DOCS_ROOT} ]]; then
  printf 'docs root not found: %s\n' "${DOCS_ROOT}" >&2
  exit 2
fi

failures=0

referenced_file="$(make_temp)"
all_docs="$(make_temp)"
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

# Reverse check. Walk docs/ as docs-relative paths. Newline-delimited here
# rather than NUL-delimited is safe because scripts/check-path-hygiene.sh
# rejects any tracked path containing a control character, so no docs/*.md
# path this walk can find carries a newline for `find`'s line-oriented
# output — or this `sed | sort` pipe — to split.
# enumerate-exempt: the listing is a `diff` operand, so diff's own status
# is what this script acts on, and the sorted newline-delimited form is
# what diff needs; check-path-hygiene.sh rejects control characters in
# tracked paths, so no path this walk can find splits across the handoff.
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
