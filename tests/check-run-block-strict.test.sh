#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/check-run-block-strict.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/run-block-strict"

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

# Composite-action scenarios live one directory deep, each holding a single
# `action.yml`, mirroring the real `.github/actions/<name>/action.yml` layout
# the lint walks. Selection is by directory rather than by basename because
# every composite file is named `action.yml`.
function expect_composite() {
  local -r scenario="$1" want_exit="$2" want_msg="$3"
  local got_exit=0 got_stderr
  got_stderr="$(ACTIONS_DIR_OVERRIDE="${FIXTURES}/${scenario}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  stderr: %s\n' "${scenario}" "${got_exit}" "${want_exit}" "${got_stderr}" >&2
    return 1
  fi
  if [[ -n ${want_msg} && ${got_stderr} != *"${want_msg}"* ]]; then
    printf 'FAIL %s: stderr missing %q\n  got: %s\n' "${scenario}" "${want_msg}" "${got_stderr}" >&2
    return 1
  fi
  printf 'OK   %s\n' "${scenario}"
}

expect good.yml 0 ""
expect good-with-comment.yml 0 ""
expect bad-missing.yml 1 "must start with"
expect bad-weak.yml 1 "must start with"
expect good-folded.yml 0 ""
expect bad-folded-missing.yml 1 "bad-folded-missing.yml: job build step[0]"
expect bad-malformed.yml 1 "could not evaluate"

expect_composite composite-good 0 ""
expect_composite composite-bad-missing 1 "composite-bad-missing/action.yml: composite step[0]"

# A composite whose YAML cannot be parsed must fail loud, exactly as a
# malformed workflow does. The fixture is generated at runtime: a committed
# unparsable `action.yml` would need its own formatter exclusion, and the
# scenario needs nothing durable beyond the parse failure itself.
malformed_dir="$(mktemp --directory)"
printf 'runs:\n  using: composite\n  steps: [this is not: valid yaml\n' \
  >"${malformed_dir}/action.yml"
malformed_exit=0
malformed_err="$(ACTIONS_DIR_OVERRIDE="${malformed_dir}" \
  "${SCRIPT}" 2>&1 >/dev/null)" || malformed_exit=$?
rm --recursive --force -- "${malformed_dir}"
if [[ ${malformed_exit} != 1 || ${malformed_err} != *"could not evaluate"* ]]; then
  printf 'FAIL malformed composite: exit %s (want 1)\n  stderr: %s\n' \
    "${malformed_exit}" "${malformed_err}" >&2
  exit 1
fi
printf 'OK   malformed composite rejected\n'

printf 'all tests passed\n'
