#!/usr/bin/env bash
# scripts/check-changelog-fresh.sh
#
# @description Guard that CHANGELOG.md's released sections match a fresh
# git-cliff regeneration, so a release that ships without its changelog update
# landing — or a manual edit to a released section — is caught rather than
# accruing silently.
#
# Only the released portion (from the first `## [<tag>]` header onward) is
# compared. The `## Unreleased` section legitimately changes with every merged
# commit, so comparing it would force a changelog regen on every PR — the
# staleness this guards is released sections lagging the release tags.
#
# A release tag is created before the changelog commit that describes it, so
# between the two there is a window in which a released section cannot yet
# exist in the committed file. Comparing it there reports staleness that no
# commit could fix: main goes red, and because the enforcing CI job is a
# required check, every open PR based before the changelog commit is blocked.
# A tag is therefore compared only when its commit is an ancestor of the most
# recent commit that touched CHANGELOG.md — only when the changelog was written
# at a point where that tag already existed. Newer tags are excluded from both
# sides of the diff. The condition is history-relative rather than time-based:
# a wall-clock grace period would either mask a genuinely dropped changelog or
# still flake, depending on how it was tuned.
#
# Blind spot this accepts: only tags predating the last CHANGELOG.md commit are
# guarded. A release whose changelog never lands stays unguarded until some
# later changelog commit exists, and two releases stacking up inside the window
# would exclude both. That is tolerable because a dropped changelog job fails
# loudly through the release-on-bump notify path — this check is the backstop,
# not the primary signal.
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

# @description Release tags that cannot yet appear in the committed changelog.
# A tag whose commit is not an ancestor of the most recent CHANGELOG.md commit
# was created after the changelog was last written, so its section could not
# have been included. Emits one tag name per line.
#
# Every git call is failure-tolerant. With no tags, no changelog commit, or no
# repository the set is empty, which compares everything — missing git
# information can only make this check stricter, never looser.
function graced_tags() {
  local last_cl tag
  last_cl="$(git log -1 --format=%H -- "${CHANGELOG}" 2>/dev/null || true)"
  if [[ -z ${last_cl} ]]; then
    return 0
  fi
  while IFS= read -r tag; do
    if [[ -z ${tag} ]]; then
      continue
    fi
    if ! git merge-base --is-ancestor "${tag}^{commit}" "${last_cl}" 2>/dev/null; then
      printf '%s\n' "${tag}"
    fi
  done < <(git tag --merged HEAD 2>/dev/null || true)
}

# @description Emit a file's comparable released portion: everything from the
# first `## [<tag>]` header onward, minus any section whose tag is excluded. A
# section runs to the next `## [` header or to end of file.
# @arg $1 file
# @arg $2 newline-separated excluded tag names (may be empty)
function released() {
  awk -v graced="$2" '
    BEGIN {
      n = split(graced, g, "\n")
      for (i = 1; i <= n; i++) {
        if (g[i] != "") {
          excluded[g[i]] = 1
        }
      }
    }
    /^## \[/ {
      started = 1
      tag = $0
      sub(/^## \[/, "", tag)
      sub(/\].*$/, "", tag)
      skipping = (tag in excluded)
    }
    started && !skipping
  ' "$1"
}

graced="$(graced_tags)"

if ! diff <(released "${CHANGELOG}" "${graced}") <(released "${tmp}" "${graced}") >/dev/null; then
  printf 'CHANGELOG.md released sections are stale vs a fresh git-cliff regen.\n' >&2
  printf 'A release shipped without the changelog job landing its update.\n' >&2
  printf 'Regenerate and commit:\n' >&2
  printf '  nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md\n' >&2
  if [[ -n ${graced} ]]; then
    printf '\nExcluded (no CHANGELOG.md commit after these tags yet): %s\n' \
      "$(printf '%s' "${graced}" | tr '\n' ' ')" >&2
  fi
  printf '\n--- committed vs regenerated (released sections only) ---\n' >&2
  diff <(released "${CHANGELOG}" "${graced}") <(released "${tmp}" "${graced}") >&2 || true
  exit 1
fi

printf 'CHANGELOG.md released sections match a fresh git-cliff regeneration\n'
exit 0
