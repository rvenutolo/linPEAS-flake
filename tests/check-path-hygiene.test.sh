#!/usr/bin/env bash
# tests/check-path-hygiene.test.sh
#
# Harness for scripts/check-path-hygiene.sh. Each scenario builds a
# throwaway git repository at runtime, because a control-byte filename
# cannot be committed to this repository: it is exactly what the lint
# under test would reject, and a `git checkout` of such a name would be
# hostile to whoever clones the tree next. No fixture here is tracked.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-path-hygiene.sh"

# Fixed identity so `git init`/`git add` never falls back to prompting
# or to ambient user config.
export GIT_AUTHOR_NAME='Test'
export GIT_AUTHOR_EMAIL='test@example.com'
export GIT_COMMITTER_NAME='Test'
export GIT_COMMITTER_EMAIL='test@example.com'

failures=0

# @description Build a throwaway git repo, stage the given paths
# (relative to the repo root), and run the lint with the repo as cwd.
# A path is staged rather than committed: `git ls-files --cached` reads
# the index directly, so no commit — and no gpg-signing config — is
# needed to exercise the tracked half of the scan.
# @arg $1 scenario name
# @arg $2 expected exit code
# @arg $3 expected substring across stdout+stderr ('' skips)
# @arg $@ remaining args: paths to create and stage; none means an
#   empty repo (the empty-scan scenario)
function run_scenario() {
  local -r name="$1"
  local -r expected_exit="$2"
  local -r expected_msg="$3"
  shift 3

  local dir
  dir="$(mktemp --directory)"
  git init --quiet "${dir}"

  local rel_path
  for rel_path in "$@"; do
    printf 'content\n' >"${dir}/${rel_path}"
    git -C "${dir}" add -- "${rel_path}"
  done

  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"

  local actual_exit=0
  (cd "${dir}" && "${SCRIPT}") >"${stdout_file}" 2>"${stderr_file}" || actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"
  harness_assert_record "${name}" "${expected_msg}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    printf 'output was:\n' >&2
    cat -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" \
      "${stdout_file}" "${stderr_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    printf 'output was:\n' >&2
    cat -- "${stdout_file}" "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --recursive --force -- "${dir}"
  rm --force -- "${stderr_file}" "${stdout_file}" "${outcome_file}"
}

function main() {
  run_scenario 'clean tree of ordinary names passes and reports its count' \
    0 '2 path(s) scanned, 0 control-byte violations' \
    'alpha.txt' 'beta.txt'

  # $'...' below is a real embedded byte in the fixture filename, not a
  # literal two-character escape, so this scenario exercises the exact
  # class the lint exists to catch: a newline inside a path.
  run_scenario 'a newline in a path is a hit' \
    1 "$'nlcase\\nfile.txt'" \
    $'nlcase\nfile.txt'

  run_scenario 'a tab in a path is a hit' \
    1 "$'tabcase\\tfile.txt'" \
    $'tabcase\tfile.txt'

  run_scenario 'a DEL byte in a path is a hit' \
    1 "$'delcase\\177file.txt'" \
    $'delcase\x7ffile.txt'

  # No paths staged and no untracked file present: the enumeration
  # itself comes back empty, which is a could-not-run, not a clean tree.
  run_scenario 'an empty scan set is a tooling error' \
    2 'enumerated 0 files via git ls-files'

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
