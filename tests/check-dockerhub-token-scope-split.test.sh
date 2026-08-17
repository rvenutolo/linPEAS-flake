#!/usr/bin/env bash
# tests/check-dockerhub-token-scope-split.test.sh
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-dockerhub-token-scope-split.sh"

failures=0

# @description Write a valid baseline workflow set into $1.
# Stubs only need the secrets.* tokens the linter greps for.
# @arg $1 target workflows dir
function write_baseline() {
  local -r dir="$1"
  mkdir --parents "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  push:\n    steps:\n      - env:\n          DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN_RW }}\n' \
    >"${dir}/release-on-bump.yml"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  sync:\n    steps:\n      - with:\n          password: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' \
    >"${dir}/dockerhub-sync.yml"
  printf 'jobs:\n  verify:\n    steps:\n      - run: echo no docker secret here\n' \
    >"${dir}/verify-latest-release.yml"
}

# @description Run the linter against a prepared dir; assert exit code and
# (for failures) a stderr substring.
# @arg $1 scenario name
# @arg $2 workflows dir
# @arg $3 expected exit code
# @arg $4 expected stderr substring (empty skips the check)
function assert_run() {
  local -r name="$1" dir="$2" expected_exit="$3" expected_stderr="$4"
  local stderr_file stdout_file outcome_file
  stderr_file="$(mktemp)"
  stdout_file="$(mktemp)"
  outcome_file="$(mktemp)"
  local actual_exit=0
  WORKFLOWS_DIR_OVERRIDE="${dir}" "${SCRIPT}" >"${stdout_file}" 2>"${stderr_file}" ||
    actual_exit=$?
  printf 'harness-assert-outcome: exit=%d\n' "${actual_exit}" >"${outcome_file}"

  if [[ ${actual_exit} -ne ${expected_exit} ]]; then
    printf 'FAIL: %s — expected exit %d, got %d\n' \
      "${name}" "${expected_exit}" "${actual_exit}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  elif [[ -n ${expected_stderr} ]] &&
    ! grep --fixed-strings --quiet -- "${expected_stderr}" "${stderr_file}"; then
    printf 'FAIL: %s — stderr missing %q\n' "${name}" "${expected_stderr}" >&2
    cat -- "${stderr_file}" >&2
    failures=$((failures + 1))
  else
    printf 'PASS: %s (exit %d)\n' "${name}" "${actual_exit}"
  fi
  harness_assert_record "${name}" "${expected_stderr}" \
    "${outcome_file}" "${stdout_file}" "${stderr_file}"
  rm --force -- "${outcome_file}" "${stdout_file}" "${stderr_file}"
}

function main() {
  local dir

  # Clean baseline passes.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  assert_run 'clean scope split passes' "${dir}" 0 ''
  rm --recursive --force -- "${dir}"

  # DELETE token leaked into release workflow.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - with:\n          password: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'DELETE token in release fails' "${dir}" 1 \
    'release-on-bump.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # DELETE token leaked into verify workflow.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - with:\n          password: ${{ secrets.DOCKERHUB_TOKEN_DELETE }}\n' \
    >>"${dir}/verify-latest-release.yml"
  assert_run 'DELETE token in verify fails' "${dir}" 1 \
    'verify-latest-release.yml: consumes secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # RW token leaked into verify workflow. verify-latest-release.yml runs its
  # Docker Hub attestation checks anonymously/read-only by design; the
  # write-scoped token is release-only, so its presence in verify is a
  # hardening regression the lint must reject.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          X: ${{ secrets.DOCKERHUB_TOKEN_RW }}\n' \
    >>"${dir}/verify-latest-release.yml"
  assert_run 'RW token in verify fails' "${dir}" 1 \
    'verify-latest-release.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  # RW token leaked into sync workflow.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          X: ${{ secrets.DOCKERHUB_TOKEN_RW }}\n' \
    >>"${dir}/dockerhub-sync.yml"
  assert_run 'RW token in sync fails' "${dir}" 1 \
    'dockerhub-sync.yml: consumes secrets.DOCKERHUB_TOKEN_RW'
  rm --recursive --force -- "${dir}"

  # Unsuffixed secret anywhere.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          Y: ${{ secrets.DOCKERHUB_TOKEN }}\n' \
    >>"${dir}/release-on-bump.yml"
  assert_run 'unsuffixed token fails' "${dir}" 1 \
    'release-on-bump.yml: secrets.DOCKERHUB_TOKEN is not authoritative'
  rm --recursive --force -- "${dir}"

  # Producer removed — positive assertion catches the silent no-op.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  printf 'jobs:\n  sync:\n    steps:\n      - run: echo nothing\n' \
    >"${dir}/dockerhub-sync.yml"
  assert_run 'missing DELETE producer fails' "${dir}" 1 \
    'dockerhub-sync.yml: must consume secrets.DOCKERHUB_TOKEN_DELETE'
  rm --recursive --force -- "${dir}"

  # Unsuffixed secret in a .yaml workflow: fixed once the suffix-check glob
  # covers *.yaml too.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf 'jobs:\n  extra:\n    steps:\n      - env:\n          Y: ${{ secrets.DOCKERHUB_TOKEN }}\n' \
    >"${dir}/bad-unsuffixed.yaml"
  assert_run 'unsuffixed token in .yaml workflow fails' "${dir}" 1 \
    'bad-unsuffixed.yaml: secrets.DOCKERHUB_TOKEN is not authoritative'
  rm --recursive --force -- "${dir}"

  # A workflow the suffix scan listed but grep could not read. grep exits 2
  # there, and scoring that as "this file names no DOCKERHUB_TOKEN" clears
  # the file of every suffix violation it carries. The lever needs a
  # permission bit, so it reproduces only where the run is not privileged
  # enough to read a mode-000 file; the guard is what makes the failure
  # legible wherever it does reproduce.
  dir="$(mktemp --directory)"
  write_baseline "${dir}"
  # shellcheck disable=SC2016 # literal GH Actions ${{ }} expression, not shell expansion
  printf '      - env:\n          Y: ${{ secrets.DOCKERHUB_TOKEN }}\n' \
    >>"${dir}/release-on-bump.yml"
  chmod 000 -- "${dir}/release-on-bump.yml"
  assert_run 'unreadable workflow is a could-not-run' "${dir}" 2 \
    'grep failed reading'
  chmod 644 -- "${dir}/release-on-bump.yml"
  rm --recursive --force -- "${dir}"

  # A workflows dir that is there but holds no YAML leaves the suffix scan
  # with nothing to read, and the run would otherwise exit 0 having asserted
  # nothing about any suffix.
  dir="$(mktemp --directory)"
  assert_run 'workflows dir with no YAML is a could-not-run' "${dir}" 2 \
    'matched 0 files via workflow YAML'
  rm --recursive --force -- "${dir}"

  harness_assert_verify || failures=$((failures + 1))

  if ((failures > 0)); then
    printf '\n%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf '\nall tests passed\n'
}

main "$@"
