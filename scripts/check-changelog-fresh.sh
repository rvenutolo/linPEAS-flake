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
# Exits 0 when released sections are fresh, 1 when stale, 2 when the check
# could not run: nix absent from PATH, the pinned git-cliff exiting non-zero,
# or an input file (CHANGELOG.md, cliff.toml) missing. A comparison that never
# happened says nothing about whether the committed changelog is fresh, so it
# must not borrow the staleness code — that sends a maintainer to regenerate a
# changelog that was never the problem. git-cliff's own stderr is passed
# through rather than silenced, so the reason is visible in the job log.
#
# Env overrides (test-only):
#   CHANGELOG_OVERRIDE  — committed changelog path (default CHANGELOG.md)
#   CLIFF_TOML_OVERRIDE — cliff config path (default cliff.toml)
#   REGEN_OVERRIDE      — pre-generated regen file; when set, the git-cliff
#     call is skipped so the comparison logic can be tested without nix
set -Eeuo pipefail
IFS=$'\n\t'
_lib_dir="${BASH_SOURCE[0]%/*}"
if [[ ${_lib_dir} == "${BASH_SOURCE[0]}" ]]; then _lib_dir=.; fi
# shellcheck source=scripts/lib/awk-path.sh
source "${_lib_dir}/lib/awk-path.sh"
# shellcheck source=scripts/lib/temp.sh
source "${_lib_dir}/lib/temp.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || printf '.')"
readonly REPO_ROOT
readonly CHANGELOG="${CHANGELOG_OVERRIDE:-${REPO_ROOT}/CHANGELOG.md}"
readonly CLIFF_TOML="${CLIFF_TOML_OVERRIDE:-${REPO_ROOT}/cliff.toml}"
readonly REGEN="${REGEN_OVERRIDE:-}"

if [[ ! -f ${CHANGELOG} ]]; then
  printf 'CHANGELOG not found: %s\n' "${CHANGELOG}" >&2
  exit 2
fi

tmp="$(make_temp)"
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
    exit 2
  fi
  # Only stdout is discarded — the regeneration lands in ${tmp}. stderr carries
  # git-cliff's and nix's own explanation of a failure and must reach the log.
  cliff_status=0
  nix shell "${REPO_ROOT}#git-cliff" --command \
    git-cliff --config "${CLIFF_TOML}" --output "${tmp}" >/dev/null ||
    cliff_status=$?
  if ((cliff_status != 0)); then
    printf 'git-cliff regeneration failed (exit %d) with config: %s\n' \
      "${cliff_status}" "${CLIFF_TOML}" >&2
    printf 'The generator could not run, so freshness was never evaluated.\n' >&2
    printf 'Fix the generator or its config; do not regenerate CHANGELOG.md.\n' >&2
    exit 2
  fi
fi

# @description Emit every release tag visible from HEAD, one per line.
# Failure-tolerant: with no tags or no repository the set is empty, which
# excludes nothing and therefore compares everything.
function visible_tags() {
  git tag --merged HEAD 2>/dev/null || true
}

# The commit that last touched the compared changelog, and whether git could
# resolve that history at all. Both states exclude nothing, but they are not
# the same finding: a path git cannot read here is not the file this
# repository tracks, while a path with no commit yet is the file with no
# history. The summary names which one held, so a pass that excluded nothing
# says why.
changelog_commit_status=0
changelog_commit="$(git log -1 --format=%H -- "${CHANGELOG}" 2>/dev/null)" ||
  changelog_commit_status=$?
readonly changelog_commit changelog_commit_status

# @description Release tags that cannot yet appear in the committed changelog.
# A tag whose commit is not an ancestor of the most recent CHANGELOG.md commit
# was created after the changelog was last written, so its section could not
# have been included. Emits one tag name per line.
#
# Every git call is failure-tolerant. With no tags, no changelog commit, or no
# repository the set is empty, which compares everything — missing git
# information can only make this check stricter, never looser. In particular,
# an unresolvable ancestry query (git-merge-base exit 128) is neither a
# confirmed ancestor nor a confirmed non-ancestor, so it does not exclude —
# only a confirmed non-ancestor (exit 1) does.
function excluded_tags() {
  local tag status tags
  if [[ -z ${changelog_commit} ]]; then
    return 0
  fi
  # Captured rather than fed through a process substitution: a redirection
  # discards its producer's status, so a producer that stopped early would
  # arrive as an empty tag set and exclude nothing — a looser verdict wearing
  # a clean exit. No status check is owed here because `visible_tags` absorbs
  # its own failure and yields the empty set by design.
  tags="$(visible_tags)"
  while IFS= read -r tag; do
    if [[ -z ${tag} ]]; then
      continue
    fi
    status=0
    git merge-base --is-ancestor "${tag}^{commit}" "${changelog_commit}" 2>/dev/null ||
      status=$?
    if [[ ${status} -eq 1 ]]; then
      printf '%s\n' "${tag}"
    fi
  done <<<"${tags}"
}

# @description Emit a file's comparable released portion: everything from the
# first `## [<tag>]` header onward, minus any section whose tag is excluded. A
# section runs to the next `## [` header or to end of file.
# @arg $1 file
# @arg $2 newline-separated excluded tag names (may be empty)
function released() {
  awk -v excluded_list="$2" '
    BEGIN {
      n = split(excluded_list, g, "\n")
      for (i = 1; i <= n; i++) {
        if (g[i] != "") {
          skip[g[i]] = 1
        }
      }
    }
    /^## \[/ {
      started = 1
      tag = $0
      sub(/^## \[/, "", tag)
      sub(/\].*$/, "", tag)
      skipping = (tag in skip)
    }
    started && !skipping
  ' "$(awk_path "$1")"
}

excluded="$(excluded_tags)"
readonly excluded

# @description Emit the tag of every released section in scope on either side
# of the comparison, one per line, sorted and de-duplicated.
function compared_sections() {
  {
    released "${CHANGELOG}" "${excluded}"
    released "${tmp}" "${excluded}"
  } | sed --quiet --regexp-extended 's/^## \[([^]]*)\].*/\1/p' | sort --unique
}

# @description Print why the release window excluded no tag. These four states
# are the whole domain of the exclusion rule and each sends an operator
# somewhere different: an unreadable history means the file being compared is
# not the one this repository tracks; no visible tag means a fetch that dropped
# them, which reduces this check to comparing nothing; the rest is the ordinary
# case where every release already has its changelog commit.
function exclusion_reason() {
  if ((changelog_commit_status != 0)); then
    printf 'the compared changelog has no readable history in this repository'
  elif [[ -z ${changelog_commit} ]]; then
    printf 'no commit has touched the compared changelog yet'
  elif [[ -z "$(visible_tags)" ]]; then
    printf 'no release tag is visible from HEAD'
  else
    printf 'every visible release tag predates the last commit to the compared changelog'
  fi
}

# @description Print what the comparison covered: the released sections in
# scope, the release tags visible from HEAD, and either the tags the release
# window excluded or why it excluded none. A bare verdict says only that two
# files agreed — not whether anything was compared, which is what a clone
# without tags or a changelog outside this work tree silently reduces this
# check to, on both the passing and the failing path.
function print_scope() {
  local sections tags
  local -a section_list=()
  sections="$(compared_sections)"
  tags="$(visible_tags)"
  if [[ -n ${sections} ]]; then
    mapfile -t section_list <<<"${sections}"
  fi
  printf 'Compared %d released section(s): %s\n' "${#section_list[@]}" \
    "$(printf '%s' "${sections:-none}" | tr '\n' ' ')"
  printf 'Release tags visible from HEAD: %s\n' \
    "$(printf '%s' "${tags:-none}" | tr '\n' ' ')"
  if [[ -n ${excluded} ]]; then
    printf '\nExcluded (no CHANGELOG.md commit after these tags yet): %s\n' \
      "$(printf '%s' "${excluded}" | tr '\n' ' ')"
  else
    printf '\nExcluded: none — %s\n' "$(exclusion_reason)"
  fi
}

if ! diff <(released "${CHANGELOG}" "${excluded}") <(released "${tmp}" "${excluded}") >/dev/null; then
  printf 'CHANGELOG.md released sections are stale vs a fresh git-cliff regen.\n' >&2
  printf 'A release shipped without the changelog job landing its update.\n' >&2
  printf 'Regenerate and commit:\n' >&2
  printf '  nix shell .#git-cliff --command git-cliff --config cliff.toml --output CHANGELOG.md\n' >&2
  printf '\n' >&2
  print_scope >&2
  printf '\n--- committed vs regenerated (released sections only) ---\n' >&2
  diff <(released "${CHANGELOG}" "${excluded}") <(released "${tmp}" "${excluded}") >&2 || true
  exit 1
fi

printf 'CHANGELOG.md released sections match a fresh git-cliff regeneration\n'
print_scope
exit 0
