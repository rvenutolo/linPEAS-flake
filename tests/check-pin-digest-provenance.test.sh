#!/usr/bin/env bash
# tests/check-pin-digest-provenance.test.sh
#
# Failure-mode harness for scripts/check-pin-digest-provenance.sh.
# Drives the check off fixture directory trees via BASE_DIR_OVERRIDE /
# HEAD_DIR_OVERRIDE; the gh CLI is replaced by a PATH stub whose
# behavior is selected with GH_STUB_MODE, so no network is touched.

set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly SCRIPT="${REPO_ROOT}/scripts/check-pin-digest-provenance.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/check-pin-digest-provenance"

failures=0

# @arg $1 scenario name
# @arg $2 head fixture dir basename
# @arg $3 GH_STUB_MODE value
# @arg $4 expected exit
# @arg $5 expected output substring (empty skips)
function run_scenario() {
  local -r name="$1" head="$2" stub_mode="$3" expected_exit="$4" expected_msg="$5"
  local out_file
  out_file="$(mktemp)"
  local actual_exit=0
  PATH="${FIXTURES}/bin:${PATH}" \
    GH_STUB_MODE="${stub_mode}" \
    BASE_DIR_OVERRIDE="${FIXTURES}/base" \
    HEAD_DIR_OVERRIDE="${FIXTURES}/${head}" \
    "${SCRIPT}" >"${out_file}" 2>&1 || actual_exit=$?
  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  rm --force -- "${out_file}"
}

# Exercises real git BASE_REF mode end to end — every run_scenario call
# above drives BASE_DIR_OVERRIDE, a directory-glob mode that shares one
# code path (scanned_files_under) with the head-side scan by
# construction and so can never expose a divergence between the two
# discovery modes. This builds a throwaway git repo under mktemp,
# commits a base tree containing a zero-level composite action pin
# (`.github/actions/action.yml`, no named subdirectory), repoints its
# SHA under an unchanged version comment, then runs the script with
# BASE_REF against that commit and no BASE_DIR_OVERRIDE — the
# git-ls-tree discovery path base_files() takes in production.
# @arg $1 scenario name
# @arg $2 expected exit
# @arg $3 expected output substring (empty skips)
function run_git_mode_scenario() {
  local -r name="$1" expected_exit="$2" expected_msg="$3"
  local repo_dir out_file
  repo_dir="$(mktemp --directory)"
  out_file="$(mktemp)"

  git -C "${repo_dir}" init --quiet --initial-branch=main
  git -C "${repo_dir}" config user.email test@example.com
  git -C "${repo_dir}" config user.name test
  mkdir --parents "${repo_dir}/.github/actions" "${repo_dir}/.github/workflows"
  cat >"${repo_dir}/.github/actions/action.yml" <<'YAML'
runs:
  steps:
    - uses: actions/setup-node@1111111111111111111111111111111111111111 # v4.0.0
YAML
  cat >"${repo_dir}/.github/workflows/wf.yml" <<'YAML'
jobs:
  a:
    steps:
      - uses: actions/checkout@2222222222222222222222222222222222222222 # v4.3.1
YAML
  git -C "${repo_dir}" add -A
  git -C "${repo_dir}" commit --quiet -m base

  # Repoint the zero-level composite action's SHA under an unchanged
  # version comment — the exact shape base_files()'s git-ls-tree scan
  # must discover identically to the head-side glob.
  cat >"${repo_dir}/.github/actions/action.yml" <<'YAML'
runs:
  steps:
    - uses: actions/setup-node@3333333333333333333333333333333333333333 # v4.0.0
YAML

  local actual_exit=0
  (cd "${repo_dir}" && env -u BASE_DIR_OVERRIDE -u HEAD_DIR_OVERRIDE BASE_REF=main "${SCRIPT}") \
    >"${out_file}" 2>&1 || actual_exit=$?

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_msg} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_msg}" "${out_file}"; then
    printf 'FAIL: %s — output missing %q\n' "${name}" "${expected_msg}" >&2
    cat -- "${out_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi

  rm --force -- "${out_file}"
  rm --recursive --force -- "${repo_dir}"
}

function main() {
  run_scenario 'unchanged tree passes' 'base' deny 0 'pin digest provenance OK'
  run_scenario 'semver digest repoint fails' 'head-semver-repoint' deny 1 'digest repointed under unchanged version'
  run_scenario 'version bump passes' 'head-version-bump' deny 0 'pin digest provenance OK'
  run_scenario 'multi-instance uniform bump passes' 'head-multi-instance-bump' deny 0 'pin digest provenance OK'
  run_scenario 'pin add/remove passes' 'head-added-removed' deny 0 'pin digest provenance OK'
  run_scenario 'octoscan digest-only repoint fails' 'head-octoscan-digest-only' deny 1 'digest repointed under unchanged version'
  run_scenario 'octoscan lockstep bump passes' 'head-octoscan-lockstep' deny 0 'pin digest provenance OK'
  run_scenario 'octoscan shape drift errors' 'head-octoscan-shape' deny 2 'octoscan digest/version pair not found'
  run_scenario 'floating repoint reachable passes' 'head-floating-repoint' reachable 0 'verified reachable'
  run_scenario 'floating repoint tag-object deref passes' 'head-floating-repoint' tagobject-reachable 0 'verified reachable'
  run_scenario 'floating repoint diverged fails' 'head-floating-repoint' diverged 1 'not reachable from upstream default branch'
  run_scenario 'floating repoint api error exits 2' 'head-floating-repoint' api-error 2 ''
  run_scenario 'quoted pin shape errors' 'head-quoted-pin' deny 2 'unrecognized uses: pin shape'
  run_scenario 'comment-less pin shape errors' 'head-commentless-pin' deny 2 'unrecognized uses: pin shape'
  run_scenario 'nested action dir repoint fails' 'head-nested-action-repoint' deny 1 'digest repointed under unchanged version'
  run_scenario 'uppercase-SHA case-only change passes' 'head-uppercase-sha-same-pin' deny 0 'pin digest provenance OK'
  run_scenario 'file rename plus repoint fails' 'head-file-rename-repoint' deny 1 'digest repointed under unchanged version'
  run_git_mode_scenario 'git BASE_REF mode: zero-level composite action repoint fails' 1 'digest repointed under unchanged version'

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
