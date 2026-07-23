#!/usr/bin/env bash
# scripts/check-changelog-fresh.sh
#
# @description Guard that CHANGELOG.md's released sections match a fresh
# git-cliff regeneration. The release-on-bump changelog job can be skipped
# (its tag-exists gate carries no recovery branch), letting the committed
# released sections silently fall behind the tags that shipped. This detects
# that drift even when the release-time job never ran.
#
# Only the released portion (from the first `## [<tag>]` header onward) is
# compared. The `## Unreleased` section legitimately changes with every merged
# commit, so comparing it would force a changelog regen on every PR — the
# staleness this guards is released sections lagging the release tags.
#
# git-cliff is invoked only via the flake-pinned `.#git-cliff` output, per the
# nix-run-pinned invariant. Offline and deterministic: git-cliff parses the PR
# number from the `(#N)` subject suffix, so no GitHub token is required. Needs
# full history + tags (fetch-depth: 0) so every release tag is visible.
#
# Exits 0 when released sections are fresh, 1 when stale (or CHANGELOG
# missing), 2 when nix is not on PATH.
#
# Env overrides (test-only):
#   CHANGELOG_OVERRIDE  — committed changelog path (default CHANGELOG.md)
#   CLIFF_TOML_OVERRIDE — cliff config path (default cliff.toml)
#   REGEN_OVERRIDE      — pre-generated regen file; when set, the git-cliff
#     call is skipped so the comparison logic can be tested without nix
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly CHANGELOG="${CHANGELOG_OVERRIDE:-${REPO_ROOT}/CHANGELOG.md}"
readonly CLIFF_TOML="${CLIFF_TOML_OVERRIDE:-${REPO_ROOT}/cliff.toml}"
readonly REGEN="${REGEN_OVERRIDE:-}"

if [[ ! -f ${CHANGELOG} ]]; then
  printf 'CHANGELOG not found: %s\n' "${CHANGELOG}" >&2
  exit 1
fi

tmp="$(mktemp)"
# shellcheck disable=SC2064
trap "rm --force -- '${tmp}'" EXIT

if [[ -n ${REGEN} ]]; then
  cp -- "${REGEN}" "${tmp}"
else
  if ! command -v nix >/dev/null 2>&1; then
    printf 'nix not found on PATH\n' >&2
    exit 2
  fi
  if [[ ! -f ${CLIFF_TOML} ]]; then
    printf 'cliff.toml not found: %s\n' "${CLIFF_TOML}" >&2
    exit 1
  fi
  nix shell "${REPO_ROOT}#git-cliff" --command \
    git-cliff --config "${CLIFF_TOML}" --output "${tmp}" >/dev/null 2>&1
fi

# Released portion: everything from the first `## [<tag>]` header onward.
function released() { awk '/^## \[/ { p = 1 } p' "$1"; }

if ! diff <(released "${CHANGELOG}") <(released "${tmp}") >/dev/null; then
  printf 'CHANGELOG.md released sections are stale vs a fresh git-cliff regen.\n' >&2
  printf 'A release shipped without the changelog job landing its update.\n' >&2
  printf 'Regenerate and commit:\n' >&2
  printf '  nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md\n' >&2
  printf '\n--- committed vs regenerated (released sections only) ---\n' >&2
  diff <(released "${CHANGELOG}") <(released "${tmp}") >&2 || true
  exit 1
fi

printf 'CHANGELOG.md released sections match a fresh git-cliff regeneration\n'
exit 0
