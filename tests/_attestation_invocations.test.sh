#!/usr/bin/env bash
# tests/_attestation_invocations.test.sh
#
# Spec-driven unit test for scripts/_attestation_invocations.awk.
set -Eeuo pipefail
IFS=$'\n\t'

repo_root="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT="${repo_root}"
readonly PARSER="${REPO_ROOT}/scripts/_attestation_invocations.awk"
readonly SLUG="rvenutolo/linPEAS-flake"

failures=0

function fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

function pass() {
  printf 'PASS: %s\n' "$1"
}

# @description Feed input to the parser and compare its full stdout.
# @arg $1 test name
# @arg $2 mode (md|other)
# @arg $3 input text (a trailing newline is added)
# @arg $4 expected stdout, verbatim
function check() {
  local -r name="$1" mode="$2" input="$3" want="$4"
  local got
  got="$(printf '%s\n' "${input}" |
    awk -v mode="${mode}" -v slug="${SLUG}" --file "${PARSER}")"
  if [[ ${got} == "${want}" ]]; then
    pass "${name}"
  else
    fail "${name}"
    printf '  want: %q\n  got:  %q\n' "${want}" "${got}" >&2
  fi
}

function test_tokenizer_splits_on_whitespace_runs() {
  check 'doubled spaces between command words still match' other \
    'gh  attestation  verify evil.json' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_tokenizer_honors_single_quotes() {
  check 'separator inside single quotes does not end the record' other \
    "gh attestation verify 'a;b.json' --repo ${SLUG}" \
    "$(printf 'ok\tgh attestation verify a;b.json --repo %s' "${SLUG}")"
}

function test_tokenizer_honors_double_quotes() {
  check 'quoted slug satisfies the pin' other \
    "gh attestation verify pin.json --repo \"${SLUG}\"" \
    "$(printf 'ok\tgh attestation verify pin.json --repo %s' "${SLUG}")"
}

function main() {
  test_tokenizer_splits_on_whitespace_runs
  test_tokenizer_honors_single_quotes
  test_tokenizer_honors_double_quotes

  if ((failures > 0)); then
    printf '%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all tests passed\n'
}

main "$@"
