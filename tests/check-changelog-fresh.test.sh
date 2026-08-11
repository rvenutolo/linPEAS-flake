#!/usr/bin/env bash
# tests/check-changelog-fresh.test.sh
#
# Harness for scripts/check-changelog-fresh.sh. Each case builds a throwaway
# git repository, because the check reads real git state: which release tags
# exist and which commit last touched CHANGELOG.md. Driving that from the live
# repository would make the cases depend on whether a release is in flight.
#
# REGEN_OVERRIDE supplies the "fresh git-cliff regeneration" side, so the
# comparison cases invoke neither nix nor git-cliff. The one case that must see
# the generator fail deliberately omits it, and runs against the real
# repository so `.#git-cliff` resolves.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-changelog-fresh.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/changelog-fresh"

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

# @description Create a branch at HEAD without switching to it.
# @arg $1 directory  @arg $2 branch name
function branch_at_head() {
  local -r dir="$1" branch="$2"
  git -C "${dir}" branch "${branch}"
}

# @description Switch to an existing branch.
# @arg $1 directory  @arg $2 branch name
function checkout_branch() {
  local -r dir="$1" branch="$2"
  git -C "${dir}" checkout --quiet "${branch}"
}

# @description Merge a branch into the current branch with --no-ff, so a real
# merge commit is guaranteed even though the merge is a fast-forward candidate.
# @arg $1 directory  @arg $2 branch name to merge in
function merge_no_ff() {
  local -r dir="$1" branch="$2"
  git -C "${dir}" merge --quiet --no-ff --message "merge: ${branch}" "${branch}"
}

# @description Run the script with the working directory inside a fixture repo.
# @arg $1 name  @arg $2 repo dir  @arg $3 regen file  @arg $4 expected exit
# @arg $5 optional CHANGELOG_OVERRIDE path
# @arg $6 optional expected stderr substring (empty skips the check)
function run_case() {
  local -r name="$1" dir="$2" regen="$3" want="$4" override="${5:-}"
  local -r expected_stderr="${6:-}"
  local got=0 stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  if [[ -n ${override} ]]; then
    (
      cd "${dir}" &&
        CHANGELOG_OVERRIDE="${override}" REGEN_OVERRIDE="${regen}" "${SCRIPT}"
    ) >"${stdout_file}" 2>"${stderr_file}" || got=$?
  else
    (
      cd "${dir}" && REGEN_OVERRIDE="${regen}" "${SCRIPT}"
    ) >"${stdout_file}" 2>"${stderr_file}" || got=$?
  fi
  printf 'harness-assert-outcome: exit=%d\n' "${got}" >"${outcome_file}"
  if [[ ${got} -ne ${want} ]]; then
    fail "${name} — expected exit ${want}, got ${got}"
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    fail "${name} — stderr missing ${expected_stderr@Q}"
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
  else
    pass "${name} (exit ${got})"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

# @description Run the script against the real repository with a cliff config
# the comparison never gets past — one the generator itself rejects, or one
# that is not there at all — so the config, not the committed changelog, is
# what fails. REGEN_OVERRIDE is deliberately unset: these are the only cases
# that reach the cliff-config path. Asserts both the exit code and that the
# diagnostic reaches stderr rather than being swallowed.
# @arg $1 name  @arg $2 cliff config path  @arg $3 expected exit
# @arg $4 expected stderr substring
function run_tooling_case() {
  local -r name="$1" config="$2" want="$3" expected_stderr="$4"
  local got=0 stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  (
    cd "${REPO_ROOT}" && CLIFF_TOML_OVERRIDE="${config}" "${SCRIPT}"
  ) >"${stdout_file}" 2>"${stderr_file}" || got=$?
  printf 'harness-assert-outcome: exit=%d\n' "${got}" >"${outcome_file}"
  if [[ ${got} -ne ${want} ]]; then
    fail "${name} — expected exit ${want}, got ${got}"
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
  elif ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    fail "${name} — stderr missing ${expected_stderr@Q}"
    printf 'stderr was:\n' >&2
    cat -- "${stderr_file}" >&2
  else
    pass "${name} (exit ${got})"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
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
  # Exercises the ancestry relationship the exclusion is keyed on, via linear
  # history: the tag is an ancestor of HEAD but no CHANGELOG.md commit has
  # landed since. This is the relationship that keeps unrelated PRs unblocked
  # on a required check; see the merge-commit case below for the same
  # relationship reproduced through an actual merge ref.
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

  # --- Case: changelog PR's own merge ref, T2 section still missing ------
  # Reproduces the actual history shape CI evaluates on a pull request: a real
  # merge commit, not linear history standing in for the ancestry relationship
  # (see the case above). T1 is tagged and its changelog lands on main. T2 is
  # tagged on a later main-line commit — a release tag is always created on
  # main before the changelog branch that describes it is cut. A changelog
  # branch is then cut from that same commit (mirroring the real changelog PR
  # workflow) and commits a changelog that omits T2's section — the exact
  # window in which the check must not go permanently blind. Merging that
  # branch back into main with --no-ff produces the merge commit that CI's
  # `HEAD` actually is on a pull-request merge ref.
  #
  # This locks in the property the whole design depends on: because the
  # release tag is always created on main before the changelog branch is cut,
  # the tag is necessarily an ancestor of the changelog commit that
  # `git log -1 -- CHANGELOG.md` resolves to here (verified separately via
  # `git merge-base --is-ancestor`) — so on the changelog PR's own merge ref
  # the tag is compared, not excluded. Its section is missing, so the check
  # must fail. This case guards that comparison: an exclusion rule that
  # wrongly swallowed this shape — excluding the tag even though it is an
  # ancestor of the resolved changelog commit — would turn this case red.
  local merge_ref="${root}/merge-ref"
  init_repo "${merge_ref}"
  commit_other "${merge_ref}" 'work-1'
  commit_changelog "${merge_ref}" "${content}/t1-only.md"
  commit_other "${merge_ref}" 'work-2'
  tag_head "${merge_ref}" '20260726-bbbbbbbb'
  branch_at_head "${merge_ref}" 'changelog-branch'
  checkout_branch "${merge_ref}" 'changelog-branch'
  commit_changelog "${merge_ref}" "${content}/t1-only-alt-unreleased.md"
  checkout_branch "${merge_ref}" 'main'
  merge_no_ff "${merge_ref}" 'changelog-branch'
  run_case 'changelog PR merge ref, T2 section still missing -> exit 1' \
    "${merge_ref}" "${content}/both.md" 1

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
  # The summary must name which of the exclusion rule's states held: a path
  # whose history git cannot read here and a path no commit has touched both
  # exclude nothing, and without the reason the two are one observation.
  run_case 'changelog outside the repo -> no exclusion -> exit 1' \
    "${outside}" "${content}/both.md" 1 "${content}/t1-only.md" \
    'Excluded: none — the compared changelog has no readable history in this repository'

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
    "${no_commit}" "${content}/both.md" 1 '' \
    'Excluded: none — no commit has touched the compared changelog yet'

  # --- Case: the generator itself fails ----------------------------------
  # A git-cliff that cannot run says nothing about whether the committed
  # changelog is fresh. Reporting it as staleness sends a maintainer to
  # regenerate a changelog that was never the problem, so it carries its own
  # exit code and a diagnostic that names the generator and the config.
  run_tooling_case 'git-cliff failing on its config exits tooling code' \
    "${FIXTURES}/bad-unparsable-template.toml" 2 'git-cliff regeneration failed'

  # --- Case: an input the comparison reads is missing --------------------
  # Neither side of the diff can be built without cliff.toml and CHANGELOG.md.
  # Freshness was never evaluated, so these carry the could-not-run code:
  # reporting staleness would send a maintainer to regenerate a changelog that
  # is not what broke.
  run_tooling_case 'missing cliff.toml exits tooling code' \
    '/nonexistent/cliff.toml' 2 'cliff.toml not found'
  run_case 'missing CHANGELOG.md -> exit 2' \
    "${fresh}" "${content}/both.md" 2 "${root}/does-not-exist.md" \
    'CHANGELOG not found'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
