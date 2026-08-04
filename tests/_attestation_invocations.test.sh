#!/usr/bin/env bash
# tests/_attestation_invocations.test.sh
#
# Spec-driven unit test for scripts/_attestation_invocations.awk.
#
# shellcheck disable=SC2016 # every test input here is literal fixture data:
# backticks and $ are markdown/shell syntax under test, never expansions.
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

function test_trailing_comment_does_not_pin() {
  check 'a pin in a trailing comment does not satisfy the check' other \
    "gh attestation verify evil.json # --repo ${SLUG}" \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_separator_ends_the_record() {
  check 'a pin after a separator does not satisfy the check' other \
    "gh attestation verify evil.json; echo \"always pass --repo ${SLUG}\"" \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_pin_inside_quoted_argument_does_not_count() {
  check 'a slug inside a quoted argument is not the pin' other \
    "gh attestation verify evil.json --predicate \"--repo ${SLUG}\"" \
    "$(printf 'bad\tgh attestation verify evil.json --predicate --repo %s' "${SLUG}")"
}

function test_chained_commands_split_into_two_records() {
  check 'each command in a chain is judged on its own' other \
    "gh attestation verify a.json --repo ${SLUG} && gh attestation verify b.json" \
    "$(printf 'ok\tgh attestation verify a.json --repo %s\nbad\tgh attestation verify b.json' "${SLUG}")"
}

function test_equals_form_pins() {
  check '--repo=<slug> satisfies the pin' other \
    "gh attestation verify pin.json --repo=${SLUG}" \
    "$(printf 'ok\tgh attestation verify pin.json --repo=%s' "${SLUG}")"
}

function test_wrong_slug_is_unpinned() {
  check 'a different slug does not satisfy the pin' other \
    'gh attestation verify pin.json --repo other/repo' \
    "$(printf 'bad\tgh attestation verify pin.json --repo other/repo')"
}

function test_doubled_backtick_span_is_seen() {
  check 'a doubled-backtick span is a span, not inter-span text' md \
    '# t

prose ``gh attestation verify evil.json`` here.' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_span_wrapping_a_single_span_is_seen() {
  check 'a doubled span wrapping a single span is one span' md \
    '# t

prose `` `gh attestation verify evil.json` `` here.' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_multi_line_span_is_seen() {
  check 'a span opened on one line and closed on the next is seen' md \
    '# t

prose `gh attestation verify
evil.json` here.' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_unterminated_span_on_runnable_line_still_seen() {
  check 'an unterminated span on a shell line does not swallow the command' other \
    'echo `gh attestation verify evil.json' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_bare_triple_in_span_is_a_mention() {
  check 'a bare command in a span is prose, not an invocation' md \
    '# t

This page mentions `gh attestation verify` in backticks.' \
    ''
}

function test_tilde_fence_body_is_runnable() {
  check 'a ~~~sh fence body is shell source' md \
    '# t

~~~sh
gh attestation verify evil.json
~~~' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_attribute_info_string_is_runnable() {
  check 'a {.sh} info string reads as sh' md \
    '# t

```{.sh}
gh attestation verify evil.json
```' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_indented_code_block_is_runnable() {
  check 'a 4-space indented line is shell source' md \
    '# t

prose:

    gh attestation verify evil.json' \
    "$(printf 'bad\tgh attestation verify evil.json')"
}

function test_backtick_fence_cannot_close_tilde_fence() {
  check 'a backtick run does not close a tilde fence' md \
    '~~~sh
gh attestation verify evil.json
```
gh attestation verify other.json
~~~' \
    "$(printf 'bad\tgh attestation verify evil.json\nbad\tgh attestation verify other.json')"
}

function test_inline_triple_backtick_is_not_a_fence() {
  check 'a line-leading triple backtick with a backtick info string is a span' md \
    '# t

```gh attestation verify evil.json```

```sh
gh attestation verify other.json
```' \
    "$(printf 'bad\tgh attestation verify evil.json\nbad\tgh attestation verify other.json')"
}

function test_diagram_fence_is_skipped() {
  check 'a mermaid fence is a diagram, not shell source' md \
    '# t

```mermaid
gh attestation verify evil.json
```' \
    ''
}

function main() {
  test_tokenizer_splits_on_whitespace_runs
  test_tokenizer_honors_single_quotes
  test_tokenizer_honors_double_quotes
  test_trailing_comment_does_not_pin
  test_separator_ends_the_record
  test_pin_inside_quoted_argument_does_not_count
  test_chained_commands_split_into_two_records
  test_equals_form_pins
  test_wrong_slug_is_unpinned
  test_doubled_backtick_span_is_seen
  test_span_wrapping_a_single_span_is_seen
  test_multi_line_span_is_seen
  test_unterminated_span_on_runnable_line_still_seen
  test_bare_triple_in_span_is_a_mention
  test_tilde_fence_body_is_runnable
  test_attribute_info_string_is_runnable
  test_indented_code_block_is_runnable
  test_backtick_fence_cannot_close_tilde_fence
  test_inline_triple_backtick_is_not_a_fence
  test_diagram_fence_is_skipped

  if ((failures > 0)); then
    printf '%d test(s) failed\n' "${failures}" >&2
    exit 1
  fi
  printf 'all tests passed\n'
}

main "$@"
