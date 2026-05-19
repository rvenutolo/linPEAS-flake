#!/usr/bin/env bash
# scripts/check-uses-sha-pinned.sh
#
# Belt-and-braces lint backup to the GitHub-side
# `sha_pinning_required` setting. Asserts every `uses:` in
# .github/workflows/*.yml (and composite actions in .github/actions/)
# ends with a full 40-hex SHA, OR is a local path-relative reference
# (./...) which is intrinsically content-addressed by the checkout.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

readonly DEFAULT_DIRS=(.github/workflows .github/actions)
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"

if [[ -n ${OVERRIDE} ]]; then
  scan_dirs=("${OVERRIDE}")
else
  scan_dirs=("${DEFAULT_DIRS[@]}")
fi

failed=0
shopt -s nullglob globstar
for dir in "${scan_dirs[@]}"; do
  [[ -d ${dir} ]] || continue
  for f in "${dir}"/*.yml "${dir}"/**/*.yml; do
    [[ -f ${f} ]] || continue
    if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
      continue
    fi
    while IFS= read -r line; do
      ref="${line#*uses:}"
      ref="${ref#"${ref%%[![:space:]]*}"}" # ltrim spaces
      # Drop trailing comment + everything after
      ref="${ref%%#*}"
      # Trim trailing whitespace
      ref="${ref%"${ref##*[![:space:]]}"}"
      # Skip empty
      [[ -z ${ref} ]] && continue
      # Path-relative composite (./...) is content-addressed by checkout
      if [[ ${ref} == ./* ]]; then
        continue
      fi
      # Expect owner/repo[/path]@<40-hex-sha>
      if [[ ! ${ref} =~ @[0-9a-f]{40}$ ]]; then
        printf '%s: %q not SHA-pinned (need owner/repo@<40-hex>)\n' "${f}" "${ref}" >&2
        failed=$((failed + 1))
      fi
    done < <(grep --extended-regexp '^\s*-?\s*uses:\s*[^[:space:]]+' "${f}" || true)
  done
done
shopt -u nullglob globstar

if ((failed > 0)); then
  printf '%d unpinned uses: reference(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
