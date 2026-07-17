#!/usr/bin/env bash
# scripts/check-changelog-links.sh
#
# @description Refuse to build if the regenerated changelog contains
# duplicate identical PR links or loses the scorecard-count preprocessor.
# Validates git-cliff OUTPUT, not the committed CHANGELOG.md formatting.
# CHANGELOG.md is generator-owned and excluded from treefmt + markdownlint,
# so no other check guards a malformed regeneration.
#
# Offline and deterministic: git-cliff parses the PR number from the `(#N)`
# subject suffix, so no GitHub token is required.
#
# git-cliff is invoked only via the flake-pinned `.#git-cliff` output, never
# an unpinned `nix run nixpkgs#git-cliff`, per the nix-run-pinned invariant.
#
# Exits 0 when both invariants hold.
# Exits 1 on any violation (duplicate links, lost preprocessor, missing file).
# Exits 2 when nix is not on PATH.
#
# Env overrides (test-only):
#   CLIFF_TOML_OVERRIDE — path to a fixture cliff.toml instead of
#     the repo-root cliff.toml

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly CLIFF_TOML="${CLIFF_TOML_OVERRIDE:-${REPO_ROOT}/cliff.toml}"

if ! command -v nix >/dev/null 2>&1; then
  printf 'nix not found on PATH\n' >&2
  exit 2
fi

if [[ ! -f ${CLIFF_TOML} ]]; then
  printf 'cliff.toml not found: %s\n' "${CLIFF_TOML}" >&2
  exit 1
fi

tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm --force -- '${tmp}'" EXIT

nix shell "${REPO_ROOT}#git-cliff" --command \
  git-cliff --config "${CLIFF_TOML}" --output "${tmp}" >/dev/null 2>&1

status=0

# Assertion 1: zero IDENTICAL adjacent PR links. The backreference \1 forces
# both captured PR numbers equal, so a legitimate distinct-PR pair
# `([#190](…)) ([#233](…))` does NOT match.
if dupes="$(grep --line-number --perl-regexp \
  '\(\[#([0-9]+)\]\([^)]*\)\) \(\[#\1\]\(' "${tmp}")"; then
  printf 'Duplicate identical PR links in regenerated changelog (%s):\n' \
    "${CLIFF_TOML}" >&2
  printf '%s\n' "${dupes}" >&2
  printf 'A cliff.toml change reintroduced double-linking. The (#N) link must\n' >&2
  printf 'come from exactly one source (the commit_preprocessor).\n' >&2
  status=1
fi

# Assertion 2: the scorecard-count preprocessor still applies.
if grep --fixed-strings --quiet '15-check allowlist' "${tmp}"; then
  printf 'Regenerated changelog contains "15-check allowlist" (%s):\n' \
    "${CLIFF_TOML}" >&2
  printf 'The scorecard-count commit_preprocessor (15-check -> 10-check) is\n' >&2
  printf 'missing from cliff.toml.\n' >&2
  status=1
fi

if ((status == 0)); then
  printf 'changelog generator output: no duplicate PR links, preprocessor intact\n'
fi

exit "${status}"
