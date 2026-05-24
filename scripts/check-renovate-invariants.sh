#!/usr/bin/env bash
# scripts/check-renovate-invariants.sh
#
# @description Lint: renovate.json carries the security-critical
# invariants — pinGitHubActionDigests, minimumReleaseAge, no top-level
# automerge, per-manager pinDigests for github-actions.

# Assert renovate.json carries the security-critical
# invariants:
#   1. extends includes "helpers:pinGitHubActionDigests"
#   2. minimumReleaseAge is set (any non-empty string)
#   3. automerge is NOT at top level (must be per-manager in packageRules)
#   4. github-actions packageRule sets pinDigests: true
#
# Honors RENOVATE_JSON_OVERRIDE for fixture testing.
# Exits 0 on intact invariants, 1 on drift.

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
readonly REPO_ROOT
readonly DEFAULT_PATH="${REPO_ROOT}/renovate.json"
readonly path="${RENOVATE_JSON_OVERRIDE:-${DEFAULT_PATH}}"

if [[ ! -f ${path} ]]; then
  printf 'renovate config not found: %s\n' "${path}" >&2
  exit 1
fi

# 1. extends includes helpers:pinGitHubActionDigests
if ! jq -e '.extends | type == "array" and any(. == "helpers:pinGitHubActionDigests")' "${path}" >/dev/null 2>&1; then
  printf 'extends does not include helpers:pinGitHubActionDigests\n' >&2
  exit 1
fi

# 2. minimumReleaseAge set (non-empty string)
if ! jq -e '.minimumReleaseAge | type == "string" and length > 0' "${path}" >/dev/null 2>&1; then
  printf 'minimumReleaseAge not set (expected e.g. "7 days")\n' >&2
  exit 1
fi

# 3. no top-level automerge
if jq -e 'has("automerge")' "${path}" >/dev/null 2>&1; then
  printf 'top-level automerge present - move to per-manager packageRules\n' >&2
  exit 1
fi

# 4. github-actions packageRule sets pinDigests
if ! jq -e '
  .packageRules // [] |
  any(
    ((.matchManagers // []) | any(. == "github-actions"))
    and
    (.pinDigests == true)
  )
' "${path}" >/dev/null 2>&1; then
  printf 'github-actions packageRule missing pinDigests: true\n' >&2
  exit 1
fi

exit 0
