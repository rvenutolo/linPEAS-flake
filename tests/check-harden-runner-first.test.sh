#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-harden-runner-first.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/harden-runner-first"
# shellcheck source=scripts/lib/locale-gap.sh
source "${REPO_ROOT}/scripts/lib/locale-gap.sh"

function expect() {
  local -r fixture="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(WORKFLOWS_DIR_OVERRIDE="${FIXTURES}" \
    WORKFLOW_FILE_FILTER="${fixture}" \
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

expect good.yml 0 ""
expect bad-missing.yml 1 "first step is"
expect bad-not-first.yml 1 "first step is"
expect bad-unpinned.yml 1 "not SHA-pinned"
expect bad-run-first.yml 1 "no first-step"
expect bad-malformed.yml 1 "could not evaluate"
expect no-such-workflow.yml 2 'selected 0 of'

# Under en_US.UTF-8 a bash `[0-9a-f]` range also matches non-ASCII
# characters, so a harden-runner ref of 39 hex digits and one such
# character would read as SHA-pinned. The workflow is built at run time
# and the whole of stderr is compared.
require_locale_gap en_US.UTF-8 || exit 1
hr_dir="$(mktemp --directory)"
printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: step-security/harden-runner@%sé\n      - run: "true"\n' \
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >"${hr_dir}/hr.yml"
hr_exit=0
hr_err="$(LC_ALL=en_US.UTF-8 WORKFLOWS_DIR_OVERRIDE="${hr_dir}" WORKFLOW_FILE_FILTER=hr.yml \
  "${SCRIPT}" 2>&1 >/dev/null)" || hr_exit=$?
rm --recursive --force -- "${hr_dir}"
hr_want="${hr_dir}/hr.yml: job a harden-runner ref step-security/harden-runner@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaé not SHA-pinned
1 job(s) missing harden-runner as first step"
if [[ ${hr_exit} != 1 || ${hr_err} != "${hr_want}" ]]; then
  printf 'FAIL non-ASCII harden-runner sha: exit %s (want 1)\n  stderr: %s\n  want:   %s\n' \
    "${hr_exit}" "${hr_err}" "${hr_want}" >&2
  exit 1
fi
printf 'OK   non-ASCII harden-runner sha rejected under en_US.UTF-8\n'

printf 'all tests passed\n'
