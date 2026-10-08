#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-setup-nix-required.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/setup-nix-required"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' \
      "${fixture}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' \
      "${fixture}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${fixture}"
}

expect good.yml 0 ""
expect bad-direct-install.yml 1 \
  "cachix/install-nix-action@b97f05dcb019ddea06450a50ef6203d2fdc19fee installs Nix outside the composite"
expect bad-missing-token.yml 1 "missing github-token"
expect bad-wrong-token.yml 1 "wrong github-token"
expect bad-malformed.yml 1 "could not evaluate"
expect bad-determinate-installer.yml 1 \
  "DeterminateSystems/nix-installer-action@2f1b1a1c8b4e3d9a7c0e5f6b8d2a4c6e0f1a3b5d installs Nix outside the composite"
expect bad-quick-install.yml 1 \
  "nixbuild/nix-quick-install-action@9d1f2e3a4b5c6d7e8f90a1b2c3d4e5f60718293a installs Nix outside the composite"
expect no-such-workflow.yml 2 'selected 0 of'

# --- job keys and merge lists, built at run time ----------------------
# @description Run the script on one workflow written at run time and
# compare the exit code and that stderr contains the message.
# @arg $1 scenario name  @arg $2 workflow text (printf format)
# @arg $3 expected exit code  @arg $4 expected stderr substring
function expect_built() {
  local -r name="$1" text="$2" want_exit="$3" want_msg="$4"
  local dir got_exit=0 got_stderr
  dir="$(mktemp --directory)"
  # shellcheck disable=SC2059 # the workflow text is the format
  printf "${text}" >"${dir}/built.yml"
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${dir}" WORKFLOW_FILE_FILTER=built.yml \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  rm --recursive --force -- "${dir}"
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${name}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    exit 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${name}" "${want_msg}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
readonly REFUSED='which GitHub Actions refuses'
readonly NIX_STEP='{uses: cachix/install-nix-action@v1}'
readonly MERGE_P='x: &p {steps: [{uses: cachix/install-nix-action@v1}]}\n'
readonly MERGE_Q='y: &q {steps: [{run: echo PAYLOAD_RAN}]}\n'
expect_built 'empty job key is refused' \
  "jobs:\n  \"\": {runs-on: x, steps: [${NIX_STEP}]}\n" 1 "${REFUSED}"
expect_built 'line-break job key is refused' \
  "jobs:\n  \"a\\\\nb\": {runs-on: x, steps: [${NIX_STEP}]}\n" 1 "${REFUSED}"
expect_built 'merge key under jobs is refused' \
  'x: &base {j: {runs-on: x, steps: [{uses: cachix/install-nix-action@v1}]}}\njobs:\n  <<: *base\n' 1 "${REFUSED}"
expect_built 'merge list reads the first mapping (installer first) as the installer' \
  "${MERGE_P}${MERGE_Q}"'jobs:\n  a: {runs-on: x, <<: [*p, *q]}\n' 1 'installs Nix outside the composite'
expect_built 'merge list reads the first mapping (run first) as a run step' \
  "${MERGE_P}${MERGE_Q}"'jobs:\n  a: {runs-on: x, <<: [*q, *p]}\n' 0 ''

printf 'all tests passed\n'
