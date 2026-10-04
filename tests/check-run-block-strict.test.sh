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
expect no-such-workflow.yml 2 'selected 0 of'

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

# Roots that exist and hold nothing leave the lint with no file to read, and
# an unasserted scan set makes that run byte-identical to a clean pass over a
# fully compliant tree. The diagnostic is asserted, not just the exit code: a
# check keyed on exit 2 alone passes just as happily when the message names
# the wrong scan set.
empty_workflows="$(mktemp --directory)"
empty_actions="$(mktemp --directory)"
empty_exit=0
empty_err="$(WORKFLOWS_DIR_OVERRIDE="${empty_workflows}" \
  ACTIONS_DIR_OVERRIDE="${empty_actions}" \
  "${SCRIPT}" 2>&1 >/dev/null)" || empty_exit=$?
rm --recursive --force -- "${empty_workflows}" "${empty_actions}"
if [[ ${empty_exit} != 2 ||
  ${empty_err} != *'matched 0 files via workflow and composite-action files'* ]]; then
  printf 'FAIL empty scan set: exit %s (want 2)\n  stderr: %s\n' \
    "${empty_exit}" "${empty_err}" >&2
  exit 1
fi
printf 'OK   empty scan set rejected\n'

# A job key is data, never expression text or a row field. Each key
# below closes a quoted segment if spliced into a `yq` expression (it
# would read the strict decoy's block, or print an environment variable
# or a file through `error()`), or holds the row separator `|`, which
# would move text into the step index. Read as data, every one names its
# own weak block.
key_dir="$(mktemp --directory)"
trap 'rm --recursive --force -- "${key_dir}"' EXIT
printf 'FILE_READ_MARK\n' >"${key_dir}/probe.txt"
# @arg $1 scenario name  @arg $2 the job key, written single-quoted
function expect_spliced_key() {
  local -r name="$1" key="$2"
  local got_exit=0 got_stderr want
  mkdir -- "${key_dir}/${name}"
  cat >"${key_dir}/${name}/w.yml" <<EOF
name: ${name}
on: push
jobs:
  '${key//\'/\'\'}':
    runs-on: ubuntu-latest
    steps:
      - name: weak
        run: |
          set -euo pipefail
          echo PAYLOAD_RAN
  decoy:
    runs-on: ubuntu-latest
    steps:
      - name: strict
        run: |
          set -Eeuo pipefail
          echo PAYLOAD_RAN
EOF
  got_stderr="$(PROBE=PAYLOAD_RAN PROBE_FILE="${key_dir}/probe.txt" WORKFLOWS_DIR_OVERRIDE="${key_dir}/${name}" \
    "${SCRIPT}" 2>&1 >/dev/null)" || got_exit=$?
  printf -v want '%s: job %q step[0] run: block must start with %q (got %q)\n1 run: block(s) missing strict-mode prelude' \
    "${key_dir}/${name}/w.yml" "${key}" 'set -Eeuo pipefail' 'set -euo pipefail'
  if [[ ${got_exit} != 1 || ${got_stderr} != "${want}" ]]; then
    printf 'FAIL %s: exit %s, want 1\n  stderr: %s\n' "${name}" "${got_exit}" "${got_stderr}" >&2
    exit 1
  fi
  printf 'OK   %s\n' "${name}"
}
expect_spliced_key job-key-reads-decoy 'x" // .jobs."decoy'
expect_spliced_key job-key-env-no-pipe 'x" // error(strenv(PROBE)) // .jobs."y'
expect_spliced_key job-key-reads-env 'x" | error(strenv(PROBE)) | ."y'
expect_spliced_key job-key-reads-file 'x" | error(load_str(strenv(PROBE_FILE))) | ."y'
expect_spliced_key job-key-quote 'k"x'
expect_spliced_key job-key-backslash 'k\x'
expect_spliced_key job-key-row-separator 'a|1'
expect_spliced_key job-key-row-separator-index 'decoy|0'

printf 'all tests passed\n'
