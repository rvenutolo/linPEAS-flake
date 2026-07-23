#!/usr/bin/env bash
# scripts/check-uses-sha-pinned.sh
#
# @description Lint: every `uses:` in `.github/workflows/*.yml` and
# `.github/actions/**/action.yml` ends with a full 40-hex SHA, or is
# a local path-relative reference.

# Belt-and-braces lint backup to the GitHub-side
# `sha_pinning_required` setting. Asserts every `uses:` in
# .github/workflows/*.yml (and composite actions in .github/actions/)
# ends with a full 40-hex SHA, OR is a local path-relative reference
# (./...) which is intrinsically content-addressed by the checkout.
#
# `uses:` values are extracted with yq (YAML-aware), so both block-style
# (`- uses: x`) and flow-style (`- { uses: x }`) steps are covered and any
# surrounding quotes are stripped before the SHA test. A yq parse failure
# fails closed — the file's references cannot be verified.
#
# Honors WORKFLOWS_DIR_OVERRIDE + WORKFLOW_FILE_FILTER for fixtures.
# Exits 0 on full coverage, 1 on any drift.

set -Eeuo pipefail
IFS=$'\n\t'

if ! command -v yq >/dev/null 2>&1; then
  printf 'check-uses-sha-pinned: yq not found on PATH\n' >&2
  exit 1
fi

readonly DEFAULT_DIRS=(.github/workflows .github/actions)
readonly OVERRIDE="${WORKFLOWS_DIR_OVERRIDE:-}"
readonly FILE_FILTER="${WORKFLOW_FILE_FILTER:-}"

if [[ -n ${OVERRIDE} ]]; then
  scan_dirs=("${OVERRIDE}")
else
  scan_dirs=("${DEFAULT_DIRS[@]}")
fi

# Extract every `uses:` value anywhere in the document, regardless of
# block/flow style, with surrounding quotes stripped by yq.
readonly USES_QUERY='.. | select(tag == "!!map" and has("uses")) | .uses'

failed=0
shopt -s nullglob globstar
for dir in "${scan_dirs[@]}"; do
  [[ -d ${dir} ]] || continue
  # A single globstar glob: `**` also matches zero segments, so `**/*.yml`
  # already covers top-level *.yml. A separate `*.yml` would match (and
  # re-scan) every top-level file a second time, double-counting violations.
  for f in "${dir}"/**/*.yml; do
    [[ -f ${f} ]] || continue
    if [[ -n ${FILE_FILTER} && "$(basename "${f}")" != "${FILE_FILTER}" ]]; then
      continue
    fi
    uses_output=''
    yq_rc=0
    uses_output="$(yq "${USES_QUERY}" "${f}" 2>/dev/null)" || yq_rc=$?
    if ((yq_rc != 0)); then
      printf '%s: yq parse failed; uses: references cannot be verified\n' "${f}" >&2
      failed=$((failed + 1))
      continue
    fi
    while IFS= read -r ref; do
      [[ -z ${ref} ]] && continue
      # Path-relative composite (./...) is content-addressed by the checkout.
      [[ ${ref} == ./* ]] && continue
      # Expect owner/repo[/path]@<40-hex-sha>.
      if [[ ! ${ref} =~ @[0-9a-f]{40}$ ]]; then
        printf '%s: %q not SHA-pinned (need owner/repo@<40-hex>)\n' "${f}" "${ref}" >&2
        failed=$((failed + 1))
      fi
    done <<<"${uses_output}"
  done
done
shopt -u nullglob globstar

if ((failed > 0)); then
  printf '%d unpinned uses: reference(s) found\n' "${failed}" >&2
  exit 1
fi
exit 0
