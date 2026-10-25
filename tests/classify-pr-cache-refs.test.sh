#!/usr/bin/env bash
# tests/classify-pr-cache-refs.test.sh
#
# Verdict matrix for scripts/classify-pr-cache-refs.sh, which picks the
# cache refs actions-cache-prune's PR-close job deletes. Offline and
# deterministic: each scenario compares the whole stdout (the refs to
# prune) and the whole stderr (the skip notice) against what is wanted.
#
# The rows that matter most: a head ref holding `&` or a gh placeholder
# such as `{owner}` is skipped, so it never reaches the cache listing
# query, while the PR's merge ref is still pruned.
set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/scripts/classify-pr-cache-refs.sh"

TMP_DIR="$(mktemp --directory)"
readonly TMP_DIR
trap 'rm --recursive --force -- "${TMP_DIR}"' EXIT

failures=0

# @description The skip notice the helper prints for a refused head ref.
# @arg $1 the head ref
function skip_notice() {
  printf 'skipping head ref %q: it holds a character outside A-Z a-z 0-9 . _ / -; its caches age out in the daily sweep\n' "$1"
}

# @arg $1 description  @arg $2 expected stdout  @arg $3 expected stderr
# remaining args: passed through to the helper
function expect_refs() {
  local -r desc="$1" want_out="$2" want_err="$3"
  shift 3
  local out err rc=0
  out="$(bash "${SCRIPT}" "$@" 2>"${TMP_DIR}/stderr")" || rc=$?
  err="$(<"${TMP_DIR}/stderr")"
  if [[ ${rc} -ne 0 || ${out} != "${want_out}" || ${err} != "${want_err}" ]]; then
    printf 'FAIL %s: exit %d, stdout %q, stderr %q; want exit 0, stdout %q, stderr %q\n' \
      "${desc}" "${rc}" "${out}" "${err}" "${want_out}" "${want_err}" >&2
    failures=1
    return
  fi
  printf 'OK   %s\n' "${desc}"
}

# @arg $1 description  @arg $2 expected exit code
# remaining args: passed through to the helper
function expect_exit() {
  local -r desc="$1" want_rc="$2"
  shift 2
  local out rc=0
  out="$(bash "${SCRIPT}" "$@" 2>/dev/null)" || rc=$?
  if [[ ${rc} -ne ${want_rc} || -n ${out} ]]; then
    printf 'FAIL %s: exit %d, stdout %q; want exit %d and no stdout\n' \
      "${desc}" "${rc}" "${out}" "${want_rc}" >&2
    failures=1
    return
  fi
  printf 'OK   %s (exit %d)\n' "${desc}" "${rc}"
}

# --- pruned: the head ref is a plain branch name ----------------------
expect_refs "a normal branch is pruned with the merge ref" \
  $'refs/pull/42/merge\nrefs/heads/fix/cache-prune' '' 42 fix/cache-prune
expect_refs "every allowed character class is pruned" \
  $'refs/pull/7/merge\nrefs/heads/Renovate/a_b-1.2/X' '' 7 Renovate/a_b-1.2/X

# --- skipped: the merge ref is still pruned ---------------------------
expect_refs "an ampersand query injection is skipped" \
  'refs/pull/42/merge' "$(skip_notice 'a&ref=refs/heads/main')" 42 'a&ref=refs/heads/main'
expect_refs "a gh placeholder is skipped" \
  'refs/pull/42/merge' "$(skip_notice 'renovate/{owner}')" 42 'renovate/{owner}'
expect_refs "a non-ASCII letter is skipped" \
  'refs/pull/42/merge' "$(skip_notice 'fix/café')" 42 'fix/café'
expect_refs "a non-ASCII digit is skipped" \
  'refs/pull/42/merge' "$(skip_notice 'fix/٣')" 42 'fix/٣'
expect_refs "a percent escape is skipped" \
  'refs/pull/42/merge' "$(skip_notice 'a%26b')" 42 'a%26b'
expect_refs "a question mark is skipped" \
  'refs/pull/42/merge' "$(skip_notice 'a?ref=x')" 42 'a?ref=x'
expect_refs "an empty head ref is skipped" \
  'refs/pull/42/merge' "$(skip_notice '')" 42 ''
expect_refs "a newline in the head ref is skipped" \
  'refs/pull/42/merge' "$(skip_notice $'a\nb')" 42 $'a\nb'

# --- operational errors -----------------------------------------------
# A PR number is part of the merge ref; anything but digits is a
# could-not-run, never a ref to prune.
expect_exit "a non-numeric PR number" 2 '42&x' main
expect_exit "an empty PR number" 2 '' main
expect_exit "a non-ASCII digit PR number" 2 '٤٢' main
expect_exit "too few arguments" 2 42
expect_exit "too many arguments" 2 42 main extra

if [[ ${failures} -ne 0 ]]; then
  printf '\nclassify-pr-cache-refs: FAILURES\n' >&2
  exit 1
fi
printf '\nclassify-pr-cache-refs: all passed\n'
