#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-nix-run-pinned.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/nix-run-pinned"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(PATHS_OVERRIDE="${FIXTURES}/${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good-shell.sh 0 ""
expect good-pinned-rev.sh 0 ""
expect good-local-flake.sh 0 ""
expect good-prose.md 0 ""
expect bad-unpinned.sh 1 "unpinned"
expect bad-fence.md 1 "unpinned"
expect bad-fence-unlabeled.md 1 "unpinned"
expect bad-run-flag.sh 1 "nix run --quiet nixpkgs#cosign -- version"
expect bad-shell-unpinned.sh 1 "nix shell nixpkgs#cosign --command cosign version"
expect bad-develop-unpinned.sh 1 "nix develop nixpkgs#foo"
expect bad-build-unpinned.sh 1 "nix build nixpkgs#bar"
expect bad-trailing-ref.sh 1 "nix shell .#jq nixpkgs#cosign --command cosign version"

# @description Drive the enumeration itself, not a fixture: with
# PATHS_OVERRIDE unset the script enumerates via `git ls-files`, and an
# unreadable index makes that producer exit 0 with no output. A status
# check cannot see that, so the empty scan set has to be the assertion.
# @arg $1 expected exit code  @arg $2 expected stderr substring
function expect_empty_scan() {
  local -r want_exit="$1" want_msg="$2"
  local got_exit=0 got_stderr index_dir
  index_dir="$(mktemp --directory)"
  got_stderr="$(cd "${REPO_ROOT}" &&
    GIT_INDEX_FILE="${index_dir}/absent.idx" "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${index_dir}"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL empty-scan: exit %s, want %s\n  stderr: %s\n' "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL empty-scan: stderr missing %q\n  got: %s\n' "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   empty-scan\n'
}

expect_empty_scan 2 "enumerated 0 files via git ls-files"

# @description Prove the NUL-safe enumeration fix directly: a workflow
# filename with an embedded newline, holding an unpinned `nix run
# nixpkgs#jq`, used to slip past this lint entirely. `git ls-files`
# (without `-z`) C-quotes such a name onto one newline-escaped line, so a
# line-oriented `while read` handoff reads it as one bogus path that then
# fails the loop's `[[ -f ]]` gate — the violation is enumerated right out
# of the scan. Built in a throwaway repo under the harness temp directory
# rather than a committed fixture: a committed newline filename would
# itself be rejected by check-path-hygiene.sh and is hostile to
# `git checkout`.
function expect_newline_workflow_name() {
  local -r name='newline-workflow-name'
  local repo_dir evil_name got_exit=0 got_stderr
  repo_dir="$(mktemp --directory)"
  mkdir --parents "${repo_dir}/.github/workflows"
  printf 'name: clean\njobs:\n  a:\n    steps:\n      - run: echo ok\n' \
    >"${repo_dir}/.github/workflows/clean.yml"
  evil_name="$(printf 'ev\nil').yml"
  printf 'name: evil\njobs:\n  a:\n    steps:\n      - run: nix run nixpkgs#jq\n' \
    >"${repo_dir}/.github/workflows/${evil_name}"
  git -C "${repo_dir}" init --quiet
  git -C "${repo_dir}" config user.email t@t.t
  git -C "${repo_dir}" config user.name t
  git -C "${repo_dir}" add --all

  got_stderr="$(cd "${repo_dir}" && "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${repo_dir}"

  if [[ ${got_exit} != 1 ]]; then
    printf 'FAIL %s: exit %s, want 1\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ ${got_stderr} != *'nixpkgs#jq'* ]]; then
    printf 'FAIL %s: stderr missing violation for the newline-named workflow\n  got: %s\n' \
      "${name}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${name}"
}

expect_newline_workflow_name

printf 'all tests passed\n'
