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

  rm --recursive --force -- "${root}"

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
