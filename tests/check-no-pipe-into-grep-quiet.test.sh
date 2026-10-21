#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
# shellcheck source=scripts/lib/harness-assert.sh
source "${REPO_ROOT}/scripts/lib/harness-assert.sh"
readonly SCRIPT="${REPO_ROOT}/scripts/check-no-pipe-into-grep-quiet.sh"
readonly FIXTURES="${REPO_ROOT}/tests/fixtures/no-pipe-into-grep-quiet"

readonly HIT_DIAG='pipe into quiet grep (grep can exit before its producer finishes; under pipefail the SIGPIPE reads a match as a miss)'

failures=0
scratch="$(make_temp --directory)"
readonly scratch
# shellcheck disable=SC2064 # expanded now on purpose: the path is fixed once created
trap "chmod --recursive u+rwx -- '${scratch}'; rm --recursive --force -- '${scratch}'" EXIT

# @description Run the lint over one scan root and assert the exit code
# plus every expected substring of its combined output. The first
# substring is the scenario's recorded assertion for the discrimination
# gate; the rest are attached to it.
# @arg $1 scenario label  @arg $2 SCAN_ROOT_OVERRIDE value
# @arg $3 wanted exit code  @arg $@ wanted output substrings
function expect() {
  local -r label="$1" root="$2" want_exit="$3"
  shift 3
  local out_file got_exit=0
  out_file="$(make_temp)"
  SCAN_ROOT_OVERRIDE="${root}" "${SCRIPT}" >"${out_file}" 2>&1 || got_exit=$?
  local got
  got="$(<"${out_file}")"
  local ok=1 want_msg
  if [[ ${got_exit} != "${want_exit}" ]]; then
    printf 'FAIL %s: exit %s, want %s\n  output: %s\n' "${label}" "${got_exit}" "${want_exit}" "${got}" >&2
    ok=0
  else
    for want_msg in "$@"; do
      if [[ ${got} != *"${want_msg}"* ]]; then
        printf 'FAIL %s: output missing %q\n  got: %s\n' "${label}" "${want_msg}" "${got}" >&2
        ok=0
      fi
    done
  fi
  if ((ok == 1)); then
    printf 'OK   %s\n' "${label}"
  else
    failures=$((failures + 1))
  fi
  harness_assert_record "${label}" "${1:-}" "${out_file}"
  if (($# > 1)); then
    shift
    for want_msg in "$@"; do
      harness_assert_also "${want_msg}"
    done
  fi
  rm --force -- "${out_file}"
}

expect single-line "${FIXTURES}/bad/single" 1 'single.sh:5: '"${HIT_DIAG}"
# Each spelling of the quiet flag is its own line, so a matcher that
# knows only some of them misses a line number.
expect bundled-flags "${FIXTURES}/bad/flags" 1 \
  'flags.sh:5: ' 'flags.sh:6: ' 'flags.sh:7: ' 'flags.sh:8: ' '4 pipe(s) into quiet grep found'
expect pipe-amp "${FIXTURES}/bad/pipeamp" 1 'pipeamp.sh:5: '
# A pipe that ends a line is reported at the line the quiet grep sits
# on, with and without a backslash after the pipe, and across a blank or
# comment line between the two.
expect multiline "${FIXTURES}/bad/multiline" 1 'multiline.sh:6: ' 'multiline.sh:12: ' \
  'multiline.sh:19: ' 'multiline.sh:22: ' '4 pipe(s) into quiet grep found'
# A quiet flag ends at a closing quote as well as at a space.
expect eval-string "${FIXTURES}/bad/eval" 1 'eval.sh:13: ' 'eval.sh:14: '
# The here-string fix, `||`, a comment naming the shape, a file operand,
# a counting grep, a line-final pipe into a grep that is not quiet, and a
# pipe inside a trailing comment: none is a pipe into a quiet grep.
expect good "${FIXTURES}/good" 0 'scanned 1 shell file(s) and 0 run: block(s)'
expect workflow-hit "${FIXTURES}/bad-workflow" 1 \
  '.github/workflows/w.yml: job smoke step[0] run: line 2: ' \
  '.github/actions/a/action.yml: composite step[0] run: line 3: '
# The `run: |` key line ends in a pipe and the body opens with a quiet
# grep: only the extracted body is read, so this is clean.
expect run-scalar "${FIXTURES}/good-workflow" 0 'scanned 0 shell file(s) and 1 run: block(s)'

# The tracked tree itself: every shell file and run: body this lint
# guards is clean. The file counts drift with the tree, so only the exit
# code is asserted.
expect live-tree "" 0

mkdir -- "${scratch}/empty"
expect empty-scan "${scratch}/empty" 2 'matched 0 files via shell, workflow and composite-action files'

# Generated here rather than committed: YAML that does not parse fails
# the formatter.
mkdir --parents -- "${scratch}/malformed/.github/workflows"
printf 'jobs: [unclosed\n' >"${scratch}/malformed/.github/workflows/w.yml"
expect malformed-yaml "${scratch}/malformed" 2 \
  '.github/workflows/w.yml: could not evaluate workflow or action with yq (malformed?)'

cp --recursive -- "${FIXTURES}/good" "${scratch}/unreadable"
chmod 000 -- "${scratch}/unreadable/ok.sh"
expect unreadable "${scratch}/unreadable" 2 'could not scan ok.sh for pipes into quiet grep'

harness_assert_verify || failures=$((failures + 1))
if ((failures > 0)); then
  printf '%d scenario(s) failed\n' "${failures}" >&2
  exit 1
fi
printf 'all tests passed\n'
