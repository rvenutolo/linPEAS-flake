#!/usr/bin/env bash
# tests/check-changelog-fresh.test.sh
#
# Harness for scripts/check-changelog-fresh.sh. Each case builds a throwaway
# git repository, because the check reads real git state: which release tags
# exist and which commit last touched CHANGELOG.md. Driving that from the live
# repository would make the cases depend on whether a release is in flight.
#
# REGEN_OVERRIDE supplies the "fresh git-cliff regeneration" side, so no case
# invokes nix or git-cliff.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-changelog-fresh.sh"

failures=0
function pass() { printf 'PASS: %s\n' "$1"; }
function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Fixed identity and timestamps so cases depend on neither ambient git config
# nor wall-clock ordering.
export GIT_AUTHOR_NAME='Test'
export GIT_AUTHOR_EMAIL='test@example.com'
export GIT_COMMITTER_NAME='Test'
export GIT_COMMITTER_EMAIL='test@example.com'
export GIT_AUTHOR_DATE='2026-01-01T00:00:00+00:00'
export GIT_COMMITTER_DATE='2026-01-01T00:00:00+00:00'

# @description Create a repo with a single seed commit and no CHANGELOG.md.
# @arg $1 directory
function init_repo() {
  local -r dir="$1"
  git init --quiet --initial-branch=main "${dir}"
  git -C "${dir}" config commit.gpgsign false
  git -C "${dir}" config tag.gpgsign false
  printf 'seed\n' >"${dir}/README.md"
  git -C "${dir}" add README.md
  git -C "${dir}" commit --quiet --message 'chore: seed'
}

# @description Commit CHANGELOG.md with the given content.
# @arg $1 directory  @arg $2 content file
function commit_changelog() {
  local -r dir="$1" content="$2"
  cp -- "${content}" "${dir}/CHANGELOG.md"
  git -C "${dir}" add CHANGELOG.md
  git -C "${dir}" commit --quiet --message 'docs: update changelog'
}

# @description Commit a change that does not touch CHANGELOG.md.
# @arg $1 directory  @arg $2 marker
function commit_other() {
  local -r dir="$1" marker="$2"
  printf '%s\n' "${marker}" >>"${dir}/README.md"
  git -C "${dir}" add README.md
  git -C "${dir}" commit --quiet --message "chore: ${marker}"
}

# @description Tag HEAD.
# @arg $1 directory  @arg $2 tag name
function tag_head() {
  git -C "$1" tag "$2"
}

# @description Run the script with the working directory inside a fixture repo.
# @arg $1 name  @arg $2 repo dir  @arg $3 regen file  @arg $4 expected exit
# @arg $5 optional CHANGELOG_OVERRIDE path
function run_case() {
  local -r name="$1" dir="$2" regen="$3" want="$4" override="${5:-}"
  local got=0
  if [[ -n ${override} ]]; then
    (
      cd "${dir}" &&
        CHANGELOG_OVERRIDE="${override}" REGEN_OVERRIDE="${regen}" "${SCRIPT}"
    ) >/dev/null 2>&1 || got=$?
  else
    (
      cd "${dir}" && REGEN_OVERRIDE="${regen}" "${SCRIPT}"
    ) >/dev/null 2>&1 || got=$?
  fi
  if [[ ${got} -eq ${want} ]]; then
    pass "${name} (exit ${got})"
  else
    fail "${name} — expected exit ${want}, got ${got}"
  fi
}

# @description Write the changelog content files used by the cases.
# @arg $1 content directory
function write_content() {
  local -r c="$1"

  # Both released sections present.
  cat >"${c}/both.md" <<'EOF'
# Changelog

## Unreleased

### Features

- A pending feature

## [20260726-bbbbbbbb] - 2026-07-26

### Features

- The newest release

## [20260715-aaaaaaaa] - 2026-07-15

### Fixes

- The older release
EOF

  # Only the older released section.
  cat >"${c}/t1-only.md" <<'EOF'
# Changelog

## Unreleased

### Features

- A pending feature

## [20260715-aaaaaaaa] - 2026-07-15

### Fixes

- The older release
EOF

  # Same released sections as t1-only.md, different Unreleased content.
  cat >"${c}/t1-only-alt-unreleased.md" <<'EOF'
# Changelog

## Unreleased

### Fixes

- A different pending change

## [20260715-aaaaaaaa] - 2026-07-15

### Fixes

- The older release
EOF

  # No released sections at all.
  cat >"${c}/none.md" <<'EOF'
# Changelog

## Unreleased

### Features

- A pending feature
EOF
}

function main() {
  local root content
  root="$(mktemp --directory)"
  # shellcheck disable=SC2064
  trap "rm --force --recursive -- '${root}'" EXIT
  content="${root}/content"
  mkdir --parents "${content}"
  write_content "${content}"

  # --- Case: changelog commit landed after the tag, section present -------
  # T1 tagged, changelog written, T2 tagged, changelog written again. The last
  # CHANGELOG.md commit post-dates both tags, so both are compared.
  local landed="${root}/landed"
  init_repo "${landed}"
  commit_other "${landed}" 'work-1'
  tag_head "${landed}" '20260715-aaaaaaaa'
  commit_changelog "${landed}" "${content}/t1-only.md"
  commit_other "${landed}" 'work-2'
  tag_head "${landed}" '20260726-bbbbbbbb'
  commit_changelog "${landed}" "${content}/both.md"
  run_case 'changelog landed after tag, section present -> exit 0' \
    "${landed}" "${content}/both.md" 0

  # --- Case: changelog commit landed after the tag, section absent --------
  # A later commit touched CHANGELOG.md without adding T2's section. That is a
  # genuine drop, not the release window.
  local dropped="${root}/dropped"
  init_repo "${dropped}"
  commit_other "${dropped}" 'work-1'
  tag_head "${dropped}" '20260715-aaaaaaaa'
  commit_changelog "${dropped}" "${content}/t1-only.md"
  commit_other "${dropped}" 'work-2'
  tag_head "${dropped}" '20260726-bbbbbbbb'
  commit_changelog "${dropped}" "${content}/t1-only-alt-unreleased.md"
  run_case 'changelog landed after tag, section absent -> exit 1' \
    "${dropped}" "${content}/both.md" 1

  # --- Case: no tags, committed released sections match the regen ---------
  local fresh="${root}/fresh"
  init_repo "${fresh}"
  commit_changelog "${fresh}" "${content}/both.md"
  run_case 'no tags, committed released == regen -> exit 0' \
    "${fresh}" "${content}/both.md" 0

  # --- Case: no tags, difference confined to the Unreleased section -------
  local unreleased="${root}/unreleased"
  init_repo "${unreleased}"
  commit_changelog "${unreleased}" "${content}/t1-only.md"
  run_case 'unreleased-only difference ignored -> exit 0' \
    "${unreleased}" "${content}/t1-only-alt-unreleased.md" 0

  # --- Case: release window, newest tag at HEAD --------------------------
  # T2 was just created and its changelog commit has not landed. The
  # regeneration renders T2's section; the committed file cannot carry it yet.
  local window="${root}/window"
  init_repo "${window}"
  commit_other "${window}" 'work-1'
  tag_head "${window}" '20260715-aaaaaaaa'
  commit_changelog "${window}" "${content}/t1-only.md"
  commit_other "${window}" 'work-2'
  tag_head "${window}" '20260726-bbbbbbbb'
  run_case 'release window, newest tag at HEAD -> exit 0' \
    "${window}" "${content}/both.md" 0

  # --- Case: release window, HEAD past the tag ---------------------------
  # The shape a PR merge ref takes during the window: the tag is an ancestor of
  # HEAD but no CHANGELOG.md commit has landed since. This is the case that
  # blocks unrelated PRs on a required check.
  local window_past="${root}/window-past"
  init_repo "${window_past}"
  commit_other "${window_past}" 'work-1'
  tag_head "${window_past}" '20260715-aaaaaaaa'
  commit_changelog "${window_past}" "${content}/t1-only.md"
  commit_other "${window_past}" 'work-2'
  tag_head "${window_past}" '20260726-bbbbbbbb'
  commit_other "${window_past}" 'work-3'
  run_case 'release window, HEAD past the tag -> exit 0' \
    "${window_past}" "${content}/both.md" 0

  # --- Case: older section missing while the newest tag is excluded ------
  # The exclusion must not swallow a real drop. T1's section is absent from a
  # changelog commit that post-dates T1, so T1 is compared and fails, even
  # though T2 is excluded.
  local older_missing="${root}/older-missing"
  init_repo "${older_missing}"
  commit_other "${older_missing}" 'work-1'
  tag_head "${older_missing}" '20260715-aaaaaaaa'
  commit_changelog "${older_missing}" "${content}/none.md"
  commit_other "${older_missing}" 'work-2'
  tag_head "${older_missing}" '20260726-bbbbbbbb'
  run_case 'older section missing while newest excluded -> exit 1' \
    "${older_missing}" "${content}/both.md" 1

  # --- Case: changelog path outside the repository ------------------------
  # The comparison runs against a file outside the work tree. If the ancestry
  # query is driven by the changelog path actually in use (the override), it
  # cannot resolve and no tag is excluded. If instead the query hardcodes
  # CHANGELOG.md, it resolves the tracked file, the newest tag is excluded, and
  # this case silently flips to exit 0. This case asserts the query is path-aware.
  local outside="${root}/outside"
  init_repo "${outside}"
  commit_other "${outside}" 'work-1'
  tag_head "${outside}" '20260715-aaaaaaaa'
  commit_changelog "${outside}" "${content}/t1-only.md"
  commit_other "${outside}" 'work-2'
  tag_head "${outside}" '20260726-bbbbbbbb'
  run_case 'changelog outside the repo -> no exclusion -> exit 1' \
    "${outside}" "${content}/both.md" 1 "${content}/t1-only.md"

  # --- Case: no CHANGELOG.md commit in history ---------------------------
  # The file exists on disk but was never committed. The ancestry query cannot
  # resolve the path under any implementation (neither hardcoded nor path-aware),
  # so no tag is excluded and everything is compared. Missing git information
  # must make the check stricter, never looser.
  local no_commit="${root}/no-commit"
  init_repo "${no_commit}"
  commit_other "${no_commit}" 'work-1'
  tag_head "${no_commit}" '20260715-aaaaaaaa'
  commit_other "${no_commit}" 'work-2'
  tag_head "${no_commit}" '20260726-bbbbbbbb'
  cp -- "${content}/t1-only.md" "${no_commit}/CHANGELOG.md"
  run_case 'no CHANGELOG.md commit in history -> no exclusion -> exit 1' \
    "${no_commit}" "${content}/both.md" 1

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
